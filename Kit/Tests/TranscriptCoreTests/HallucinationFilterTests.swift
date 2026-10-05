import Testing
@testable import TranscriptCore

private func seg(_ text: String) -> Segment { Segment(start: 0, end: 2, text: text) }

@Test func dropsKnownPhraseWhenQuiet() {
    #expect(HallucinationFilter().shouldDrop(seg(" Thank you."), rmsEnergy: 0.001))
}

@Test func keepsKnownPhraseWhenSpeech() {
    #expect(!HallucinationFilter().shouldDrop(seg(" Thank you."), rmsEnergy: 0.05))
}

@Test func keepsNormalTextWhenQuiet() {
    #expect(!HallucinationFilter().shouldDrop(seg("The derivative of x squared"), rmsEnergy: 0.001))
}

@Test func matchesPhraseVariants() {
    let f = HallucinationFilter()
    #expect(f.shouldDrop(seg("THANKS FOR WATCHING!"), rmsEnergy: 0))
    #expect(f.shouldDrop(seg("Subtitles by the Amara.org community"), rmsEnergy: 0))
    #expect(f.shouldDrop(seg("you"), rmsEnergy: 0))
    #expect(f.shouldDrop(seg(" Bye. "), rmsEnergy: 0))
    #expect(!f.shouldDrop(seg("Thank you for coming to class today"), rmsEnergy: 0))
}
