import CaptureKit
import Foundation
import Testing
import TranscriptCore
@testable import SessionKit

@MainActor
private func controller(root: URL, permissions: FakePermissions) -> SessionController {
    SessionController(root: root, transcriber: FakeTranscriber(), makeSource: { _ in FakeSource() },
                      notes: nil, retranscribe: { false }, permissions: permissions)
}

@MainActor @Test func deniedMicrophoneBlocksStart() async throws {
    let root = try makeTempRoot()
    let session = controller(root: root, permissions: FakePermissions(microphoneStatus: .denied))
    await session.start(.microphone)
    guard case .failed(let message) = session.state else {
        Issue.record("expected .failed, got \(session.state)")
        return
    }
    #expect(message.contains("Microphone"))
    #expect(session.blockedPermission == .microphone)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@MainActor @Test func deniedScreenRecordingBlocksStart() async throws {
    let root = try makeTempRoot()
    let session = controller(root: root, permissions: FakePermissions(screenStatus: .denied))
    await session.start(.computerAudio)
    guard case .failed(let message) = session.state else {
        Issue.record("expected .failed, got \(session.state)")
        return
    }
    #expect(message.contains("Screen Recording"))
    #expect(session.blockedPermission == .computerAudio)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@MainActor @Test func undeterminedPermissionIsRequested() async throws {
    let granted = controller(root: try makeTempRoot(),
                             permissions: FakePermissions(microphoneStatus: .notDetermined, grantOnRequest: true))
    await granted.start(.microphone)
    #expect(granted.state == .recording)
    await granted.stop()

    let refused = controller(root: try makeTempRoot(),
                             permissions: FakePermissions(microphoneStatus: .notDetermined, grantOnRequest: false))
    await refused.start(.microphone)
    #expect(refused.blockedPermission == .microphone)
}

@MainActor @Test func grantedPermissionClearsEarlierBlock() async throws {
    var permissions = FakePermissions(microphoneStatus: .denied)
    let root = try makeTempRoot()
    let first = controller(root: root, permissions: permissions)
    await first.start(.microphone)
    #expect(first.blockedPermission == .microphone)
    permissions.microphoneStatus = .granted
    // A new controller stands in for the user fixing it in System Settings.
    let second = controller(root: root, permissions: permissions)
    await second.start(.microphone)
    #expect(second.blockedPermission == nil)
    await second.stop()
}

@Test func settingsLinksPointAtPrivacyPanes() {
    #expect(SystemPermissions.settingsURL(for: .microphone).absoluteString
        == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    #expect(SystemPermissions.settingsURL(for: .computerAudio).absoluteString
        == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
}
