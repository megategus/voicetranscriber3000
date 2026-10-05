import Foundation
import Observation

/// User preferences, stored in `UserDefaults`. The API key is not here; see `KeychainStore`.
@MainActor @Observable
public final class AppSettings {
    public static let defaultOutputFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Transcripts", isDirectory: true)

    private enum Key {
        static let outputFolder = "outputFolder"
        static let retranscribeAfterStop = "retranscribeAfterStop"
        static let showFloatingPanel = "showFloatingPanel"
    }

    @ObservationIgnored private let defaults: UserDefaults

    public var outputFolder: URL {
        didSet { defaults.set(outputFolder.path, forKey: Key.outputFolder) }
    }

    public var retranscribeAfterStop: Bool {
        didSet { defaults.set(retranscribeAfterStop, forKey: Key.retranscribeAfterStop) }
    }

    public var showFloatingPanel: Bool {
        didSet { defaults.set(showFloatingPanel, forKey: Key.showFloatingPanel) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        outputFolder = defaults.string(forKey: Key.outputFolder)
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultOutputFolder
        retranscribeAfterStop = defaults.object(forKey: Key.retranscribeAfterStop) as? Bool ?? true
        showFloatingPanel = defaults.bool(forKey: Key.showFloatingPanel)
    }
}
