import Testing

@Test func wordErrorRateHelper() {
    #expect(abs(wordErrorRate(reference: "a b c", hypothesis: "a x c") - 1.0 / 3) < 0.001)
    #expect(wordErrorRate(reference: "Hello, World!", hypothesis: "hello world") == 0)
    #expect(wordErrorRate(reference: "a b c d", hypothesis: "a c d e") == 0.5)
    #expect(wordErrorRate(reference: "mister quilter", hypothesis: "Mr. Quilter") == 0)
}
