import Testing
@testable import TranscriptCore

private func seg(_ start: Double, _ text: String) -> Segment {
    Segment(start: start, end: start + 2, text: text)
}

private func A(_ text: String) -> Segment { seg(0, text) }
private func B(_ text: String) -> Segment { seg(2, text) }

@Test func confirmsWhenTwoDecodesAgree() {
    var c = SegmentConfirmer()
    let first = c.ingest([A("Hello world"), B("this is")])
    #expect(first.confirmed.isEmpty)
    #expect(first.partial == "Hello world this is")
    let second = c.ingest([A("Hello world"), B("this is a test")])
    #expect(second.confirmed == [A("Hello world")])
    #expect(second.partial == "this is a test")
    #expect(c.confirmedEnd == 2)
}

@Test func doesNotConfirmChangedText() {
    var c = SegmentConfirmer()
    #expect(c.ingest([A("Hello word")]).confirmed.isEmpty)
    #expect(c.ingest([A("Hello world")]).confirmed.isEmpty)
    #expect(c.ingest([A("Hello world")]).confirmed == [A("Hello world")])
}

@Test func comparesTextIgnoringCaseAndWhitespace() {
    var c = SegmentConfirmer()
    _ = c.ingest([A(" Hello world"), B("x")])
    #expect(c.ingest([A("hello world "), B("x y")]).confirmed == [A("hello world ")])
}

@Test func doesNotConfirmWhenStartsDiffer() {
    var c = SegmentConfirmer()
    _ = c.ingest([seg(0, "Hello"), B("x")])
    #expect(c.ingest([seg(0.8, "Hello"), B("x y")]).confirmed.isEmpty)
}

@Test func confirmsOnlyAgreeingPrefix() {
    var c = SegmentConfirmer()
    _ = c.ingest([A("one"), B("two"), seg(4, "three")])
    let r = c.ingest([A("one"), B("TOO"), seg(4, "three"), seg(6, "four")])
    #expect(r.confirmed == [A("one")])
    #expect(r.partial == "TOO three four")
}

@Test func neverReconfirms() {
    var c = SegmentConfirmer()
    _ = c.ingest([A("Hello world"), B("this is")])
    _ = c.ingest([A("Hello world"), B("this is a test")])
    #expect(c.ingest([A("Hello world"), B("this is a test")]).confirmed == [B("this is a test")])
    #expect(c.ingest([A("Hello world"), B("this is a test")]).confirmed.isEmpty)
    #expect(c.confirmedEnd == 4)
}

@Test func singleDecodeConfirmsNothingUntilFlush() {
    var c = SegmentConfirmer()
    let r = c.ingest([A("Hello world"), B("this is")])
    #expect(r.confirmed.isEmpty)
    #expect(c.flush() == [A("Hello world"), B("this is")])
    #expect(c.flush().isEmpty)
    #expect(c.confirmedEnd == 4)
}

@Test func flushAfterPartialConfirmation() {
    var c = SegmentConfirmer()
    _ = c.ingest([A("Hello world"), B("this is")])
    _ = c.ingest([A("Hello world"), B("this is a test")])
    #expect(c.flush() == [B("this is a test")])
}
