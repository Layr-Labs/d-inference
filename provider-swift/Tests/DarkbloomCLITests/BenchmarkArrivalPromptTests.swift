import Testing
@testable import darkbloom

@Suite("benchmark arrival prompt topology")
struct BenchmarkArrivalPromptTests {
    @Test("exactly four valid lengths retain positional order")
    func valid() {
        #expect(Benchmark.parseArrivalPromptLengths("8192, 512,512, 2") == [8192, 512, 512, 2])
    }

    @Test("qualification widths retain every row and reject width mismatch")
    func qualificationWidths() {
        for width in [1, 2, 4, 6, 8, 12, 16] {
            let lengths = Array(repeating: 1024, count: width)
            let raw = lengths.map(String.init).joined(separator: ",")
            #expect(Benchmark.parseArrivalPromptLengths(raw, width: width) == lengths)
            #expect(Benchmark.parseArrivalPromptLengths(raw, width: width + 1) == nil)
        }
        #expect(Benchmark.parseArrivalPromptLengths("1024", width: 0) == nil)
        #expect(Benchmark.parseArrivalPromptLengths("1024", width: 17) == nil)
    }

    @Test("invalid fields cannot silently disappear or shift row identities")
    func invalid() {
        for raw in ["8192,,512,512", "8192,bad,512,512", "8192,0,512,512", "8192,1,512,512",
                    "8192,512,512", "8192,512,512,512,", "8192,bad,512,512,512",
                    "8192,-1,512,512,512", ""] {
            #expect(Benchmark.parseArrivalPromptLengths(raw) == nil)
        }
    }
}
