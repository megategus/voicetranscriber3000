import Testing
@testable import TranscriptCore

@Test func segmentEquality() {
    #expect(Segment(start: 1, end: 2, text: "a") == Segment(start: 1, end: 2, text: "a"))
}
