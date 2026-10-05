import Testing
@testable import TranscriptCore

@Test func formatsUnderOneHour() {
    #expect(formatTimestamp(754) == "12:34")
    #expect(formatTimestamp(5) == "00:05")
}

@Test func formatsPastOneHour() {
    #expect(formatTimestamp(3600) == "1:00:00")
    #expect(formatTimestamp(3725) == "1:02:05")
}

@Test func formatsLine() {
    #expect(formatLine(Segment(start: 65, end: 70, text: "Hello")) == "[01:05] Hello")
}

@Test func parsesTranscriptLines() {
    let text = "[00:05] Hello there.\n\n[01:02:03] Past one hour.\nnot a line\n[12:30]   spaced  \n"
    #expect(parseTranscript(text) == [
        Segment(start: 5, end: 5, text: "Hello there."),
        Segment(start: 3723, end: 3723, text: "Past one hour."),
        Segment(start: 750, end: 750, text: "spaced"),
    ])
}

@Test func parseRoundTripsFormatLine() {
    let segments = [Segment(start: 61, end: 61, text: "a"), Segment(start: 4000, end: 4000, text: "b")]
    #expect(parseTranscript(segments.map(formatLine).joined(separator: "\n")) == segments)
}
