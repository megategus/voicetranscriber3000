import Foundation

public enum SessionRecovery {
    /// Session folders left by a crash or quit mid-session: they still hold `audio.caf`
    /// (deleted only after a successful `.m4a` export) and have no `notes.md`.
    public static func unfinished(in root: URL) -> [URL] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        return children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { fm.fileExists(atPath: $0.appendingPathComponent(SessionWriter.FileName.audioCAF).path) }
            .filter { !fm.fileExists(atPath: $0.appendingPathComponent(SessionWriter.FileName.notes).path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
