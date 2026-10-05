import Foundation
import Testing
@testable import SessionKit

/// Uses a throwaway service name so the real `VoiceTranscriber` entry is never touched.
@Suite(.serialized)
struct KeychainStoreTests {
    let store = KeychainStore(service: "VoiceTranscriberTests-\(UUID().uuidString)", account: "test-account")

    @Test func loadReturnsNilWhenNothingSaved() {
        #expect(store.load() == nil)
    }

    @Test func saveLoadDeleteRoundTrip() throws {
        defer { try? store.delete() }
        try store.save("  fake-value-1\n")
        #expect(store.load() == "fake-value-1")
        try store.save("fake-value-2")          // overwrite
        #expect(store.load() == "fake-value-2")
        try store.delete()
        #expect(store.load() == nil)
    }

    @Test func deleteWhenMissingDoesNotThrow() throws {
        try store.delete()
    }

    @Test func saveRejectsEmptyValue() {
        #expect(throws: KeychainStore.Error.empty) { try store.save("   ") }
    }

    @Test func apiKeyEntryUsesAgreedNames() {
        #expect(KeychainStore.apiKey.service == "VoiceTranscriber")
        #expect(KeychainStore.apiKey.account == "anthropic-api-key")
    }
}
