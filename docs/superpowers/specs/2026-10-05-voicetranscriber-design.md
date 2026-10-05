# VoiceTranscriber — Design Spec

Date: 2026-10-05
Status: Approved in brainstorming, pending written-spec review

## 1. Purpose

A personal macOS app that listens to a lecture, video, or online meeting,
shows a live English transcript, answers questions about what was said while
the session runs, and produces high-quality study notes when the session ends.

### Agreed requirements

| Decision | Choice |
|---|---|
| Audience | Single user, own machine. No accounts, no server, no installer. |
| Platform | macOS on Apple Silicon (M3/M4 or newer), macOS 14+ |
| Language | English only (Whisper language forced to `en`) |
| Audio source | One source per session, picked at Start: **Computer audio** or **Microphone**. Never mixed. |
| Speaker labels | None |
| Live assistance | Live transcript + on-demand questions. No auto-refreshing notes. |
| Transcription | Local, on-device (WhisperKit, `large-v3-turbo`) |
| Notes / Q&A | Claude API, model `claude-opus-5-5` |
| Output | Markdown files in a user-chosen folder, one folder per session |
| Raw audio | Kept, as AAC `.m4a` |
| Final re-transcription | On by default; Settings toggle to disable |
| Notes format | One fixed structure for every session (section 6.3) |
| Stack | Native Swift app (Swift 6, SwiftUI). The user is learning Swift. |

### Non-goals (v1)

- Hiding the app from screen sharing, proctoring, or other participants.
- Mixing microphone and computer audio; speaker diarization.
- Languages other than English.
- Auto-updating notes during a session.
- In-app session library or search (Finder/Spotlight/Obsidian cover this).
- Any OS other than macOS; Intel Macs.

## 2. Architecture

```
┌──────────────┐  16 kHz Float32   ┌──────────────┐  TranscriptEvent  ┌─────────────────┐
│ AudioSource  │ ────────────────▶ │ Transcriber  │ ────────────────▶ │ TranscriptStore │
│  (protocol)  │        │          │  (protocol)  │                   │     (actor)     │
│ • SystemAudio│        │          │ • WhisperKit │                   │ ordered segments│
│ • Microphone │        ▼          └──────────────┘                   └───────┬─────────┘
└──────────────┘  ┌──────────────┐                                            │
                  │ AudioRecorder│ → audio.caf → audio.m4a    ┌───────────────┼────────────┐
                  └──────────────┘                            ▼               ▼            ▼
                                                     SessionWriter      Assistant      SwiftUI
                                                     transcript*.md   (ask / notes)    live view
                                                     notes.md, qa.md       │
                                                                       ClaudeClient
                                                                   (HTTPS + SSE)
```

### Units

| Unit | Responsibility | Depends on |
|---|---|---|
| `AudioSource` (protocol) | `start() async throws -> AsyncStream<AudioChunk>`, `stop()`. Emits 16 kHz mono Float32 chunks with a running sample offset. | — |
| `SystemAudioSource` | ScreenCaptureKit `SCStream` with `capturesAudio = true`, `excludesCurrentProcessAudio = true`; resamples with `AVAudioConverter`. | ScreenCaptureKit, AVFoundation |
| `MicrophoneSource` | `AVAudioEngine` input node tap; resamples; restarts on `AVAudioEngineConfigurationChange`. | AVFoundation |
| `AudioRecorder` | Tees the same chunks to `audio.caf` (crash-safe); converts to `audio.m4a` (AAC) on stop. | AVFoundation |
| `Transcriber` (protocol) | `transcribe(AsyncStream<AudioChunk>) -> AsyncStream<TranscriptEvent>` for live; `transcribeFile(URL, progress:) async throws -> [Segment]` for the final pass. | — |
| `WhisperKitTranscriber` | WhisperKit implementation; model `large-v3-turbo`, `language: "en"`. Loaded at app launch. | WhisperKit (SPM) |
| `TranscriptStore` (actor) | Holds finalized `Segment`s in order plus the current partial text. Single source of truth for the UI, writer, and assistant. Exposes 5-minute blocks (section 6.1). | — |
| `SessionWriter` | Creates the session folder; appends each final segment to `transcript.live.md`; writes `transcript.md`, `notes.md`, `qa.md`; renames the folder once a title exists. | FileManager |
| `ClaudeClient` | Minimal Messages API client: request building, SSE streaming via `URLSession.bytes(for:)`, error mapping, retries. Reads the API key from Keychain. | URLSession, Security |
| `Assistant` | Owns prompts. `ask(_:)` and the quick actions; `makeNotes(from:)`. | ClaudeClient, TranscriptStore |
| `SessionController` (`@MainActor @Observable`) | State machine: `idle → recording → finalizing → done` (plus `failed`). Wires all units. | all of the above |
| UI | Main window: source picker, Start/Stop, live transcript, Ask panel. Settings window. Optional floating `NSPanel` for the live transcript. | SessionController |
| `KeychainStore` | Save/load/delete the Anthropic API key. | Security |

Core types:

```swift
struct AudioChunk { let samples: [Float]; let startSample: Int64 }   // 16 kHz mono
struct Segment   { let start: TimeInterval; let end: TimeInterval; let text: String }
enum TranscriptEvent { case partial(String), final(Segment) }
enum AudioSourceKind { case computerAudio, microphone }
```

## 3. Session lifecycle

1. **Idle.** Model is preloaded at launch; Start shows a progress indicator
   until the model is ready. User picks the source.
2. **Start.** Permission pre-check for the chosen source (section 7). Create
   the session folder named `yyyy-MM-dd HH-mm`. Start source, recorder,
   and transcriber.
3. **Recording.** Live loop (section 4). Ask panel is enabled.
4. **Stop → Finalizing.**
   1. Stop the source; close `audio.caf`; convert to `audio.m4a`; delete
      the `.caf` after a successful conversion.
   2. `transcript.live.md` is already complete; it is never overwritten.
   3. If **Re-transcribe full audio after stopping** is on: run
      `transcribeFile` on `audio.m4a` with a progress bar and a Cancel
      button, then write `transcript.md`. If it is off, fails, or is
      cancelled: `transcript.md` is a copy of `transcript.live.md`.
   4. Generate notes from `transcript.md` (section 6.2), write `notes.md`,
      rename the folder to `yyyy-MM-dd HH-mm <title>`.
5. **Done.** Buttons: Reveal in Finder, Open notes. If notes failed:
   **Generate notes** (retry).

## 4. Live transcription

- Audio chunks append to a rolling buffer. About every 1 s, the
  transcriber decodes the unconfirmed region of the buffer (capped at 30 s).
- **Stalled confirmation:** if unconfirmed audio exceeds 25 s, every segment
  of the latest decode except the last is confirmed as is, so the 30 s cap
  never drops audio from the live transcript.
- **Confirmation rule:** a segment becomes final when two consecutive
  decodes agree on it. Final segments are emitted as `.final`, never
  revised, and the buffer is trimmed past them. The remaining text is
  emitted as `.partial` and shown in gray.
- Target latency: partial text about 1 s, final text about 2–4 s.
- **Timestamps** come from the sample offset (`startSample / 16000`), not
  from the system clock, so they match `audio.m4a` exactly.
- **Silence:** voice-activity detection gates decoding, so silent windows
  are not decoded.
- **Hallucination filter:** final segments matching a short blocklist
  ("Thank you.", "Thanks for watching.", "Subtitles by …", etc.) are dropped
  only when the segment's audio energy is below the speech threshold.
- **Lag:** if the newest final segment ends more than 10 s behind the
  newest audio, show a "Transcription lagging" badge. Audio is never
  dropped; the final pass covers gaps.

## 5. Session folder

Default root: `~/Documents/Transcripts/` (changeable in Settings).

```
2026-10-05 14-30 <Title>/
  audio.m4a
  transcript.live.md     # live transcript, appended line by line
  transcript.md          # final-pass transcript (or copy of live)
  notes.md
  qa.md                  # questions asked during the session and answers
```

Transcript line format: `[mm:ss] text` (`[h:mm:ss]` past one hour).

## 6. Claude integration

### 6.1 Common

- Endpoint `POST https://api.anthropic.com/v1/messages`, headers
  `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json`.
- Model `claude-opus-5-5`, `thinking: {type: "adaptive"}`, `stream: true`.
- Refusal fallback enabled: `anthropic-beta: server-side-fallback-2026-07-01`
  and `fallbacks: "default"`. Always check `stop_reason` before using content.
- **Transcript blocks for caching:** the transcript is sent as a list of
  text content blocks, one per 5-minute window. Completed windows are
  byte-stable. A window is *completed* only when its time has passed **and**
  a final segment from a later window exists, because final text arrives
  2–4 s after the audio and could otherwise change a block already sent.
  Silent windows are kept as empty strings so window numbers never shift,
  but empty blocks are left out of requests (the API rejects empty text
  blocks). `cache_control: {type: "ephemeral"}` is placed on the last
  non-empty completed block; the in-progress block and the question follow it.

### 6.2 Ask (during recording)

- System prompt (frozen): answer from the transcript; cite timestamps as
  `[mm:ss]`; anything not in the transcript is marked *(background)*; say
  plainly when the transcript does not contain the answer.
- Each question is independent (no chat history).
- Quick actions: **Summarize last 5 min**, **What did I miss?**
  (since the last question or the last 5 minutes), **Explain the last term**.
- `output_config: {effort: "low"}`, `max_tokens: 4000`.
- Answer streams into the Ask panel and is appended to `qa.md`.

### 6.3 Notes (after Stop)

- Input: full `transcript.md` in one request (a 3-hour lecture is about
  40k tokens; no chunking).
- `output_config: {effort: "high", format: <JSON schema>}`,
  `max_tokens: 64000`, streamed.
- Output schema: `{ "title": string, "notes_markdown": string }`.
  `title` is 3–8 words, safe for a folder name after sanitizing.
- Fixed notes structure, used for every session:

```
# <Title>
## TL;DR               3–5 bullets
## Key concepts        per concept:
                         In simple terms: 1–2 plain-language sentences
                         Explanation:     full explanation
                         Why it matters:  one line
                         [timestamp]
## Detailed notes      by topic; explained in prose + bullets; [timestamps]
## Examples & formulas each worked step by step, simple version first; LaTeX for math
## Action items        only if the speaker stated any; otherwise omitted
```

- The notes must be understandable without having watched the session.
  Added background knowledge is marked *(background)*.
- Garbled or unclear parts are marked inline: `⚠ unclear in recording [mm:ss]`.

## 7. Error handling

| Failure | Behavior |
|---|---|
| Screen Recording / Microphone permission denied | Checked before Start; blocking screen with "Open System Settings". |
| No audio for 30 s | Banner: "No audio detected — check the source." |
| Audio device change (mic mode) | Restart `AVAudioEngine`; session continues. |
| App crash or quit mid-session | Audio is in `audio.caf`, transcript in `transcript.live.md`. On next launch, detect sessions without `notes.md` and with a `.caf`, and offer **Recover**, which runs the Finalizing steps. |
| Claude 401 | Open Settings with "API key rejected". |
| Claude 429 / 5xx / network error | Two retries with exponential backoff; then an inline Retry button. |
| Claude refusal after fallback | Inline message; transcript is unaffected. |
| Notes generation fails | Session ends in `done` with a **Generate notes** button. |
| Final re-transcription fails or is cancelled | `transcript.md` = copy of `transcript.live.md`; continue to notes. |
| Transcription lag | Badge (section 4). |

## 8. Settings

- Anthropic API key (stored in Keychain; never in files or source).
- Output folder.
- Re-transcribe full audio after stopping (default: on).
- Show floating transcript panel (default: off).

## 9. Testing

- **Unit (Swift Testing):**
  - Confirmation rule, using a fake `Transcriber` that returns scripted decodes.
  - `TranscriptStore` ordering and 5-minute block stability.
  - Request building: cache breakpoint placement, schema, headers.
  - SSE parser against recorded API stream fixtures (text, thinking,
    refusal, error events).
  - Hallucination filter.
  - `SessionWriter` folder layout, line format, and rename sanitizing.
  - Recovery detection.
- **Accuracy:** a short public-domain English clip (LibriVox) with a
  reference transcript; fails if word error rate is above a set threshold.
- **Claude:** mocked via `URLProtocol`; one opt-in live test, skipped when
  no API key is configured.
- **Manual checklist:** YouTube lecture via computer audio; Zoom call via
  computer audio; in-room lecture via microphone; crash during recording
  followed by Recover.

## 10. Build notes

- Xcode 16+, Swift 6, SwiftUI; WhisperKit via Swift Package Manager.
- Sign with a free Apple ID "Personal Team" certificate so macOS privacy
  permissions persist across rebuilds.
- Entitlements / Info.plist: `NSMicrophoneUsageDescription`; Screen
  Recording permission is requested by ScreenCaptureKit at first use.

## 11. Cost estimate

Pricing for `claude-opus-5-5`: $4 / MTok input, $20 / MTok output,
$0.20 / MTok cache reads.

- Notes for a 1-hour session (~13k transcript tokens): about $0.10–0.20.
- Each question: about $0.01–0.02 with caching.
