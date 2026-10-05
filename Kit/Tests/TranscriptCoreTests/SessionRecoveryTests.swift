import Foundation
import Testing
@testable import TranscriptCore

@Test func recoveryFindsUnfinished() throws {
    let root = try makeTempDir()
    let fm = FileManager.default
    func folder(_ name: String, files: [String]) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        for file in files {
            try Data().write(to: url.appendingPathComponent(file))
        }
        return url
    }
    let a = try folder("A", files: ["audio.caf"])
    _ = try folder("B", files: ["audio.caf", "notes.md"])
    _ = try folder("C", files: ["audio.m4a"])
    try Data().write(to: root.appendingPathComponent("stray.caf"))

    let found = SessionRecovery.unfinished(in: root)
    #expect(found.map(\.standardizedFileURL) == [a.standardizedFileURL])
}

@Test func recoveryOnMissingRootIsEmpty() {
    let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    #expect(SessionRecovery.unfinished(in: missing).isEmpty)
}
