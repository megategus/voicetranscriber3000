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
