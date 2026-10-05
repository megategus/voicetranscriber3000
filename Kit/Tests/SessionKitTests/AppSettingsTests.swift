import Foundation
import Testing
@testable import SessionKit

@MainActor
private func freshDefaults() -> UserDefaults {
    let name = "AppSettingsTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor @Test func defaultsWhenNothingStored() {
    let settings = AppSettings(defaults: freshDefaults())
    #expect(settings.outputFolder == FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Transcripts", isDirectory: true))
    #expect(settings.retranscribeAfterStop == true)
    #expect(settings.showFloatingPanel == false)
    #expect(settings.model == .opus55)
    #expect(settings.notesEffort == "high")
}

@MainActor @Test func changesPersistAcrossInstances() {
    let defaults = freshDefaults()
    let settings = AppSettings(defaults: defaults)
    settings.outputFolder = URL(fileURLWithPath: "/tmp/Lectures", isDirectory: true)
    settings.retranscribeAfterStop = false
    settings.showFloatingPanel = true
    settings.model = .sonnet55
    settings.notesEffort = "medium"

    let reloaded = AppSettings(defaults: defaults)
    #expect(reloaded.model == .sonnet55)
    #expect(reloaded.notesEffort == "medium")
    #expect(reloaded.outputFolder.path == "/tmp/Lectures")
    #expect(reloaded.retranscribeAfterStop == false)
    #expect(reloaded.showFloatingPanel == true)
}

@MainActor @Test func ignoredRecoveriesPersist() {
    let defaults = freshDefaults()
    let settings = AppSettings(defaults: defaults)
    #expect(settings.ignoredRecoveries.isEmpty)
    settings.ignoreRecovery(URL(fileURLWithPath: "/tmp/T/2026-10-05 09-00", isDirectory: true))
    #expect(AppSettings(defaults: defaults).ignoredRecoveries == ["/tmp/T/2026-10-05 09-00"])
}

@MainActor @Test func appearanceDefaultsToSystemAndPersists() {
    let defaults = freshDefaults()
    let settings = AppSettings(defaults: defaults)
    #expect(settings.appearance == .system)
    settings.appearance = .dark
    #expect(AppSettings(defaults: defaults).appearance == .dark)
    #expect(Appearance.allCases == [.system, .light, .dark])
}
