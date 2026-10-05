import Foundation

/// Owns one session folder and the files in it. Calls are serialized with a lock,
/// so it can be shared between the live loop, the assistant, and the controller.
public final class SessionWriter: @unchecked Sendable {
    public enum FileName {
        public static let audioCAF = "audio.caf"
        public static let audioM4A = "audio.m4a"
        public static let liveTranscript = "transcript.live.md"
        public static let finalTranscript = "transcript.md"
        public static let notes = "notes.md"
        public static let qa = "qa.md"
        public static let usage = "usage.md"
    }

    private let lock = NSLock()
    private var _folder: URL
    /// The dated part of the folder name, e.g. `2026-10-05 14-30`, used when renaming.
    private let stem: String

    /// Opens an existing session folder (used for recovery). Does not create anything.
    public init(folder: URL) {
        _folder = folder
        let name = folder.lastPathComponent
        stem = Self.datedPrefix(of: name) ?? name
    }

    /// Creates `<root>/yyyy-MM-dd HH-mm` (with ` (2)`, ` (3)`… on collision) and an empty
    /// `transcript.live.md` inside it.
    public static func create(root: URL, date: Date) throws -> SessionWriter {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let stem = folderDateFormatter.string(from: date)
        let folder = uniqueURL(in: root, baseName: stem)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data().write(to: folder.appendingPathComponent(FileName.liveTranscript))
        return SessionWriter(folder: folder)
    }

    public var folder: URL {
        lock.withLock { _folder }
    }

    public var audioCAF: URL { folder.appendingPathComponent(FileName.audioCAF) }
    public var audioM4A: URL { folder.appendingPathComponent(FileName.audioM4A) }
    public var liveTranscriptURL: URL { folder.appendingPathComponent(FileName.liveTranscript) }
    public var finalTranscriptURL: URL { folder.appendingPathComponent(FileName.finalTranscript) }
    public var notesURL: URL { folder.appendingPathComponent(FileName.notes) }
    public var qaURL: URL { folder.appendingPathComponent(FileName.qa) }

    public func appendLive(_ segment: Segment) throws {
        try lock.withLock {
            try append(formatLine(segment) + "\n", to: _folder.appendingPathComponent(FileName.liveTranscript))
        }
    }

    public func writeFinalTranscript(_ segments: [Segment]) throws {
        let text = segments.map { formatLine($0) + "\n" }.joined()
        try lock.withLock {
            try Data(text.utf8).write(to: _folder.appendingPathComponent(FileName.finalTranscript), options: .atomic)
        }
    }

    public func copyLiveToFinal() throws {
        try lock.withLock {
            let live = _folder.appendingPathComponent(FileName.liveTranscript)
            let data = (try? Data(contentsOf: live)) ?? Data()
            try data.write(to: _folder.appendingPathComponent(FileName.finalTranscript), options: .atomic)
        }
    }

    public func writeNotes(_ markdown: String) throws {
        try lock.withLock {
            try Data(markdown.utf8).write(to: _folder.appendingPathComponent(FileName.notes), options: .atomic)
        }
    }

    public func writeUsage(_ markdown: String) throws {
        try lock.withLock {
            try Data(markdown.utf8).write(to: _folder.appendingPathComponent(FileName.usage), options: .atomic)
        }
    }

    public func appendQA(question: String, answer: String, at time: TimeInterval) throws {
        let entry = "## [\(formatTimestamp(time))] \(question)\n\n\(answer)\n\n"
        try lock.withLock {
            try append(entry, to: _folder.appendingPathComponent(FileName.qa))
        }
    }

    /// Renames the folder to `<yyyy-MM-dd HH-mm> <sanitized title>`.
    public func rename(title: String) throws {
        try lock.withLock {
            let parent = _folder.deletingLastPathComponent()
            let target = Self.uniqueURL(in: parent, baseName: "\(stem) \(Self.sanitize(title))")
            try FileManager.default.moveItem(at: _folder, to: target)
            _folder = target
        }
    }

    /// Makes a title safe for a folder name.
    public static func sanitize(_ title: String) -> String {
        var s = title.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: ": ", with: " - ")
        for ch in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"] {
            s = s.replacingOccurrences(of: ch, with: "-")
        }
        while s.contains("  ") {
            s = s.replacingOccurrences(of: "  ", with: " ")
        }
        s = trimEdges(s)
        while s.hasPrefix(".") {
            s.removeFirst()
            s = trimEdges(s)
        }
        if s.count > 80 {
            s = trimEdges(String(s.prefix(80)))
        }
        return s.isEmpty ? "Untitled" : s
    }

    // MARK: - Private

    private static func trimEdges(_ s: String) -> String {
        var s = s.trimmingCharacters(in: .whitespaces)
        while let last = s.last, last == "-" || last == " " || last == "." {
            s.removeLast()
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func append(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try Data().write(to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private static func uniqueURL(in parent: URL, baseName: String) -> URL {
        let fm = FileManager.default
        var candidate = parent.appendingPathComponent(baseName, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(baseName) (\(n))", isDirectory: true)
            n += 1
        }
        return candidate
    }

    private static func datedPrefix(of name: String) -> String? {
        let prefix = String(name.prefix(16))
        guard prefix.count == 16, folderDateFormatter.date(from: prefix) != nil else { return nil }
        return prefix
    }

    private static let folderDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return f
    }()
}
