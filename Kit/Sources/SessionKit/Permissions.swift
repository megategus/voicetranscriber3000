import AVFoundation
import CoreGraphics
import Foundation
import TranscriptCore

public enum PermissionStatus: Equatable, Sendable {
    case granted
    case denied
    case notDetermined
}

public protocol PermissionChecking: Sendable {
    func microphone() async -> PermissionStatus
    func screenRecording() async -> PermissionStatus
    /// Asks macOS for the permission a source needs; true when it is granted.
    func request(_ kind: AudioSourceKind) async -> Bool
}

extension PermissionChecking {
    func status(for kind: AudioSourceKind) async -> PermissionStatus {
        switch kind {
        case .microphone: await microphone()
        case .computerAudio: await screenRecording()
        }
    }
}

/// The real macOS privacy checks.
public struct SystemPermissions: PermissionChecking {
    public init() {}

    public func microphone() async -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// macOS only says granted or not; "not" is treated as undetermined so Start asks once.
    public func screenRecording() async -> PermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
    }

    public func request(_ kind: AudioSourceKind) async -> Bool {
        switch kind {
        case .microphone:
            await AVCaptureDevice.requestAccess(for: .audio)
        case .computerAudio:
            // Shows the system prompt the first time; the grant only takes effect after the
            // app is relaunched, so this returns false until then.
            CGRequestScreenCaptureAccess()
        }
    }

    /// The Privacy & Security pane for a source's permission.
    public static func settingsURL(for kind: AudioSourceKind) -> URL {
        let pane = switch kind {
        case .microphone: "Privacy_Microphone"
        case .computerAudio: "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    public static func deniedMessage(for kind: AudioSourceKind) -> String {
        switch kind {
        case .microphone:
            "Microphone access is off for VoiceTranscriber. Turn it on in System Settings → Privacy & Security → Microphone."
        case .computerAudio:
            "Screen Recording access is needed to capture computer audio. Turn on VoiceTranscriber in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen the app."
        }
    }
}
