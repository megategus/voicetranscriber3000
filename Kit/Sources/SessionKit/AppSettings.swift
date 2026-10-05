import AssistantKit
import Foundation
import Observation

/// Light or dark look; `system` follows macOS.
public enum Appearance: String, CaseIterable, Sendable {
    case system, light, dark

    public var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// User preferences, stored in `UserDefaults`. The API key is not here; see `KeychainStore`.
@MainActor @Observable
public final class AppSettings {
    public static let defaultOutputFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Transcripts", isDirectory: true)

    private enum Key {
        static let outputFolder = "outputFolder"
        static let retranscribeAfterStop = "retranscribeAfterStop"
        static let showFloatingPanel = "showFloatingPanel"
        static let ignoredRecoveries = "ignoredRecoveries"
        static let model = "claudeModel"
        static let notesEffort = "notesEffort"
        static let appearance = "appearance"
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

    /// The Claude model for questions and notes.
    public var model: ClaudeModel {
        didSet { defaults.set(model.rawValue, forKey: Key.model) }
    }

    /// Effort for notes: "high", "medium", or "low". Lower effort thinks less (cheaper).
    public var notesEffort: String {
        didSet { defaults.set(notesEffort, forKey: Key.notesEffort) }
    }

    public var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    public var assistantConfiguration: AssistantConfiguration {
        AssistantConfiguration(model: model, notesEffort: notesEffort)
    }

    /// Paths of interrupted sessions the user chose not to recover; not offered again.
    public private(set) var ignoredRecoveries: [String] {
        didSet { defaults.set(ignoredRecoveries, forKey: Key.ignoredRecoveries) }
    }

    public func ignoreRecovery(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        if !ignoredRecoveries.contains(path) {
            ignoredRecoveries.append(path)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        outputFolder = defaults.string(forKey: Key.outputFolder)
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultOutputFolder
        retranscribeAfterStop = defaults.object(forKey: Key.retranscribeAfterStop) as? Bool ?? true
        showFloatingPanel = defaults.bool(forKey: Key.showFloatingPanel)
        ignoredRecoveries = defaults.stringArray(forKey: Key.ignoredRecoveries) ?? []
        model = defaults.string(forKey: Key.model).flatMap(ClaudeModel.init(rawValue:)) ?? .opus55
        notesEffort = defaults.string(forKey: Key.notesEffort) ?? "high"
        appearance = defaults.string(forKey: Key.appearance).flatMap(Appearance.init(rawValue:)) ?? .system
    }
}
