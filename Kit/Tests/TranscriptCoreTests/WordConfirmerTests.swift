import Testing
@testable import TranscriptCore

/// Words 0.5 s apart starting at `from`, each 0.4 s long.
private func words(_ text: String, from: Double = 0) -> [Word] {
    text.split(separator: " ").enumerated().map { i, w in
        Word(start: from + Double(i) * 0.5, end: from + Double(i) * 0.5 + 0.4, text: String(w))
    }
}

@Test func confirmsCommonPrefixOfTwoDecodes() {
    var c = WordConfirmer()
    #expect(c.ingest(words("hello world this")).isEmpty)
    let confirmed = c.ingest(words("hello world this is"))
    #expect(confirmed.map(\.text) == ["hello", "world", "this"])
    #expect(c.pending.map(\.text) == ["is"])
    #expect(c.confirmedEnd == 1.4)
}

@Test func comparesIgnoringCaseAndPunctuation() {
    var c = WordConfirmer()
    _ = c.ingest(words("Hello, world"))
    #expect(c.ingest(words("hello World.")).map(\.text) == ["hello", "World."])
}

@Test func stopsAtFirstDisagreement() {
    var c = WordConfirmer()
    _ = c.ingest(words("one two three"))
    #expect(c.ingest(words("one too three four")).map(\.text) == ["one"])
    #expect(c.pending.map(\.text) == ["too", "three", "four"])
}

@Test func neverReconfirmsWordsBeforeConfirmedEnd() {
    var c = WordConfirmer()
    _ = c.ingest(words("a b c"))
    _ = c.ingest(words("a b c d"))          // confirms a b c, end 1.4
    #expect(c.ingest(words("a b c d e")).map(\.text) == ["d"])
    #expect(c.ingest(words("a b c d e")).map(\.text) == ["e"])
    #expect(c.ingest(words("a b c d e")).isEmpty)
}

/// After the buffer is trimmed, Whisper often repeats the last confirmed word with a
/// slightly later timestamp. It must not be confirmed twice.
@Test func dropsRepeatedWordsAtStartOfNextWindow() {
    var c = WordConfirmer()
    _ = c.ingest(words("we start the test"))
    _ = c.ingest(words("we start the test now"))   // confirms up to "test", end 1.9
    // Midpoint 2.0 is past confirmedEnd (1.9), so only the repeat check can catch it.
    let repeated = [Word(start: 1.8, end: 2.2, text: " test")] + words("now we go", from: 2.2)
    #expect(c.ingest(repeated).map(\.text) == ["now"])
}

@Test func keepsRealRepetitionLaterInTime() {
    var c = WordConfirmer()
    _ = c.ingest(words("very good"))
    _ = c.ingest(words("very good indeed"))         // confirms "very good", end 0.9
    let later = words("very good", from: 5)       // said again, seconds later
    _ = c.ingest(later)
    #expect(c.ingest(later).map(\.text) == ["very", "good"])
}

@Test func singleDecodeConfirmsNothingUntilFlush() {
    var c = WordConfirmer()
    #expect(c.ingest(words("hello world")).isEmpty)
    #expect(c.flush().map(\.text) == ["hello", "world"])
    #expect(c.flush().isEmpty)
    #expect(c.confirmedEnd == 0.9)
}

@Test func confirmAllButLastLeavesTail() {
    var c = WordConfirmer()
    _ = c.ingest(words("one two three"))
    #expect(c.confirmAllButLast().map(\.text) == ["one", "two"])
    #expect(c.confirmedEnd == 0.9)
    #expect(c.flush().map(\.text) == ["three"])
}
