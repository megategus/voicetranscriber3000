import Foundation
import Testing
@testable import TranscriptCore

func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("VTTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let date = Calendar.current.date(
    from: DateComponents(year: 2026, month: 10, day: 5, hour: 14, minute: 30, second: 12))!

private func read(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

@Test func createsDatedFolder() throws {
    let root = try makeTempDir()
    let writer = try SessionWriter.create(root: root, date: date)
    #expect(writer.folder.lastPathComponent == "2026-10-05 14-30")
    #expect(FileManager.default.fileExists(atPath: writer.folder.path))
    #expect(writer.audioCAF.lastPathComponent == "audio.caf")
    #expect(writer.audioM4A.lastPathComponent == "audio.m4a")
}

@Test func createsRootIfMissing() throws {
    let root = try makeTempDir().appendingPathComponent("Transcripts", isDirectory: true)
    let writer = try SessionWriter.create(root: root, date: date)
    #expect(FileManager.default.fileExists(atPath: writer.folder.path))
}

@Test func createsSuffixOnCollision() throws {
    let root = try makeTempDir()
    _ = try SessionWriter.create(root: root, date: date)
    let second = try SessionWriter.create(root: root, date: date)
    let third = try SessionWriter.create(root: root, date: date)
    #expect(second.folder.lastPathComponent == "2026-10-05 14-30 (2)")
    #expect(third.folder.lastPathComponent == "2026-10-05 14-30 (3)")
}

@Test func liveTranscriptExistsEmptyAtStart() throws {
    let writer = try SessionWriter.create(root: try makeTempDir(), date: date)
    #expect(try read(writer.folder.appendingPathComponent("transcript.live.md")) == "")
}

@Test func appendsLiveLines() throws {
    let writer = try SessionWriter.create(root: try makeTempDir(), date: date)
    try writer.appendLive(Segment(start: 1, end: 2, text: "a"))
    try writer.appendLive(Segment(start: 2, end: 3, text: "b"))
    #expect(try read(writer.folder.appendingPathComponent("transcript.live.md")) == "[00:01] a\n[00:02] b\n")
}

@Test func copyLiveToFinal() throws {
    let writer = try SessionWriter.create(root: try makeTempDir(), date: date)
    try writer.appendLive(Segment(start: 1, end: 2, text: "a"))
    try writer.copyLiveToFinal()
    try writer.copyLiveToFinal() // overwrites without error
    #expect(try read(writer.folder.appendingPathComponent("transcript.md"))
            == read(writer.folder.appendingPathComponent("transcript.live.md")))
}

@Test func writesFinalTranscript() throws {
    let writer = try SessionWriter.create(root: try makeTempDir(), date: date)
    try writer.writeFinalTranscript([
        Segment(start: 0, end: 1, text: "x"),
        Segment(start: 3700, end: 3701, text: "y"),
    ])
    #expect(try read(writer.folder.appendingPathComponent("transcript.md")) == "[00:00] x\n[1:01:40] y\n")
}

@Test func writesNotes() throws {
    let writer = try SessionWriter.create(root: try makeTempDir(), date: date)
    try writer.writeNotes("# Limits\n")
    #expect(try read(writer.folder.appendingPathComponent("notes.md")) == "# Limits\n")
}

@Test func sanitizesTitle() {
    #expect(SessionWriter.sanitize("Intro: Calculus/Limits?") == "Intro - Calculus-Limits")
    #expect(SessionWriter.sanitize("..hidden") == "hidden")
    #expect(SessionWriter.sanitize("a  \n b") == "a b")
    #expect(SessionWriter.sanitize(String(repeating: "x", count: 100)).count == 80)
    #expect(SessionWriter.sanitize(" /:?. ") == "Untitled")
    #expect(SessionWriter.sanitize("") == "Untitled")
}

@Test func renameAppendsTitle() throws {
    let writer = try SessionWriter.create(root: try makeTempDir(), date: date)
    try writer.appendLive(Segment(start: 1, end: 2, text: "a"))
    try writer.rename(title: "Limits")
    #expect(writer.folder.lastPathComponent == "2026-10-05 14-30 Limits")
    #expect(FileManager.default.fileExists(atPath: writer.folder.appendingPathComponent("transcript.live.md").path))
    // Writes keep working after the rename.
    try writer.writeNotes("n")
    #expect(try read(writer.folder.appendingPathComponent("notes.md")) == "n")
}

@Test func renameAvoidsCollision() throws {
    let root = try makeTempDir()
    let a = try SessionWriter.create(root: root, date: date)
    let b = try SessionWriter.create(root: root, date: date)
    try a.rename(title: "Limits")
    try b.rename(title: "Limits")
    #expect(b.folder.lastPathComponent == "2026-10-05 14-30 Limits (2)")
}

@Test func appendsQA() throws {
    let writer = try SessionWriter.create(root: try makeTempDir(), date: date)
    try writer.appendQA(question: "What is a limit?", answer: "<answer>", at: 42)
    try writer.appendQA(question: "Next?", answer: "Yes.", at: 61)
    #expect(try read(writer.folder.appendingPathComponent("qa.md"))
            == "## [00:42] What is a limit?\n\n<answer>\n\n## [01:01] Next?\n\nYes.\n\n")
}

@Test func opensExistingFolderForRecovery() throws {
    let first = try SessionWriter.create(root: try makeTempDir(), date: date)
    try first.appendLive(Segment(start: 1, end: 2, text: "a"))
    let reopened = SessionWriter(folder: first.folder)
    try reopened.appendLive(Segment(start: 2, end: 3, text: "b"))
    #expect(try read(first.folder.appendingPathComponent("transcript.live.md")) == "[00:01] a\n[00:02] b\n")
}
