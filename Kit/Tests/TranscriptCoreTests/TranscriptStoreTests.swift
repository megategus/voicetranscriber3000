import Testing
@testable import TranscriptCore

private func seg(_ start: Double, _ text: String? = nil) -> Segment {
    Segment(start: start, end: start + 2, text: text ?? "at \(Int(start))")
}

@Test func keepsSegmentsInOrder() async {
    let store = TranscriptStore()
    await store.append(seg(10))
    await store.append(seg(5))
    #expect(await store.segments.map(\.start) == [5, 10])
}

@Test func blocksSplitAtFiveMinutes() async {
    let store = TranscriptStore()
    for start in [10.0, 290, 310, 650] { await store.append(seg(start)) }
    let blocks = await store.completedBlocks(now: 700)
    #expect(blocks.count == 2)
    #expect(blocks[0] == "[00:10] at 10\n[04:50] at 290")
    #expect(blocks[1] == "[05:10] at 310")
    #expect(await store.currentBlock(now: 700) == "[10:50] at 650")
}

@Test func completedBlocksAreStable() async {
    let store = TranscriptStore()
    for start in [10.0, 290, 310, 650] { await store.append(seg(start)) }
    let before = await store.completedBlocks(now: 700)
    await store.append(seg(680))
    let after = await store.completedBlocks(now: 720)
    #expect(Array(after.prefix(2)) == before)
}

@Test func completedBlocksIncludeEmptyWindows() async {
    // A silent 5-minute window still occupies its position, so block indices stay stable.
    let store = TranscriptStore()
    await store.append(seg(10))
    await store.append(seg(650))
    let blocks = await store.completedBlocks(now: 700)
    #expect(blocks == ["[00:10] at 10", ""])
}

@Test func textFromTimestamp() async {
    let store = TranscriptStore()
    for start in [10.0, 299, 300, 450] { await store.append(seg(start)) }
    #expect(await store.text(from: 300) == "[05:00] at 300\n[07:30] at 450")
}

@Test func partialAndReset() async {
    let store = TranscriptStore()
    #expect(await store.isEmpty)
    await store.append(seg(1))
    await store.setPartial("growing")
    #expect(await store.partial == "growing")
    #expect(await !store.isEmpty)
    await store.reset()
    #expect(await store.isEmpty)
    #expect(await store.partial == "")
}

@Test func blockStaysOpenUntilLaterSpeechArrives() async {
    // A segment spoken at 4:58 can be confirmed after the clock passes 5:00.
    let store = TranscriptStore()
    await store.append(seg(10))
    #expect(await store.completedBlocks(now: 302).isEmpty)
    await store.append(seg(298, "late"))
    #expect(await store.completedBlocks(now: 303).isEmpty)
    await store.append(seg(305))
    #expect(await store.completedBlocks(now: 306) == ["[00:10] at 10\n[04:58] late"])
}
