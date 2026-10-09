import Testing
@testable import ProviderCore

@Suite("Benchmark instruction prefix audit")
struct InstructionPrefixAuditTests {
    @Test func trustedEmptyUserBoundaryUsesLastRoleAndVerifiesActualPrefix() {
        let marker = [91, 92]
        // The same marker occurs inside a tool description before the real role.
        let header = [1, 91, 92, 7, 8, 91, 92, 99, 100]
        let full = [1, 91, 92, 7, 8, 91, 92, 21, 22, 23]
        #expect(BenchmarkInstructionPrefix.verifiedBoundary(fullTokens: full,
            emptyUserTokens: header, userMarker: marker) == 7)
        // A mismatched real boundary must not fall back to the earlier literal
        // marker merely because that shorter prefix still matches.
        #expect(BenchmarkInstructionPrefix.verifiedBoundary(fullTokens: [1, 91, 92, 7, 8, 0, 0],
            emptyUserTokens: header, userMarker: marker) == nil)
        #expect(BenchmarkInstructionPrefix.verifiedBoundary(fullTokens: [1, 2, 3],
            emptyUserTokens: header, userMarker: marker) == nil)
        #expect(BenchmarkInstructionPrefix.verifiedBoundary(fullTokens: full,
            emptyUserTokens: [1, 2, 3], userMarker: marker) == nil)
        #expect(BenchmarkInstructionPrefix.verifiedBoundary(fullTokens: full,
            emptyUserTokens: header, userMarker: []) == nil)
    }
}
