import Testing
@testable import darkbloom

@Suite("benchmark arrival prompt topology")
struct BenchmarkArrivalPromptTests {
    @Test("exactly four valid lengths retain positional order")
    func valid() {
        #expect(Benchmark.parseArrivalPromptLengths("8192, 512,512, 2") == [8192, 512, 512, 2])
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
