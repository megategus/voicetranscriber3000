import Testing
@testable import TranscriptCore

private func w(_ start: Double, _ text: String, length: Double = 0.4) -> Word {
    Word(start: start, end: start + length, text: text)
}

@Test func breaksAfterSentencePunctuation() {
    var b = LineBuilder()
    let lines = b.add([w(0, " Hello"), w(0.5, " world."), w(1, " Next")])
    #expect(lines == [Segment(start: 0, end: 0.9, text: "Hello world.")])
    #expect(b.openText == "Next")
}

@Test func breaksAfterQuestionAndExclamation() {
    var b = LineBuilder()
    let lines = b.add([w(0, "Why?"), w(0.5, "Because!"), w(1, "So")])
    #expect(lines.map(\.text) == ["Why?", "Because!"])
}

@Test func doesNotBreakAfterAbbreviation() {
    var b = LineBuilder()
    #expect(b.add([w(0, "Mr."), w(0.5, "Quilter"), w(1, "said")]).isEmpty)
    #expect(b.openText == "Mr. Quilter said")
}

@Test func breaksBeforeLongPause() {
    var b = LineBuilder()
    let lines = b.add([w(0, "and"), w(0.5, "then"), w(2.5, "later")])
    #expect(lines == [Segment(start: 0, end: 0.9, text: "and then")])
    #expect(b.openText == "later")
}

@Test func breaksWhenLineGetsLong() {
    var b = LineBuilder()
    let many = (0..<40).map { w(Double($0) * 0.5, "w\($0)") }
    let lines = b.add(many)
    #expect(lines.count == 1)
    #expect(lines[0].end - lines[0].start <= LineBuilder.maxDuration)
    #expect(lines[0].start == 0)
}

@Test func finishReturnsOpenLine() {
    var b = LineBuilder()
    _ = b.add([w(3, " no"), w(3.5, " period ")])
    #expect(b.finish() == Segment(start: 3, end: 3.9, text: "no period"))
    #expect(b.finish() == nil)
    #expect(b.openText.isEmpty)
}
