import Foundation
import Testing
@testable import DarkbloomClusterRuntime

// MiMo step evidence: the highest candidates of one logits row read from its
// raw bytes, and the runtime line the pair driver keeps. CPU only; no model.

@Suite("MiMo step evidence (CPU)")
struct MiMoStepEvidenceTests {
    private static func bfloat16Bytes(_ values: [Float]) -> Data {
        var data = Data()
        for value in values {
            // Exact for values that are already bfloat16 (low 16 bits zero).
            var half = UInt16(truncatingIfNeeded: value.bitPattern >> 16).littleEndian
            withUnsafeBytes(of: &half) { data.append(contentsOf: $0) }
        }
        return data
    }

    @Test func bfloat16RowRanksHighestFirstWithTiesInTokenOrder() throws {
        // 264 and 279 tie exactly; 7 is higher; a NaN never ranks.
        var row = [Float](repeating: -4, count: 300)
        row[264] = 23.5; row[279] = 23.5; row[7] = 24; row[11] = 23.25; row[12] = .nan
        let top = try MiMoStepEvidence.candidates(rowBytes: Self.bfloat16Bytes(row), dtype: "bfloat16")
        #expect(top.map(\.tokenID) == [7, 264, 279, 11])
        #expect(top.map(\.logit) == [24, 23.5, 23.5, 23.25])
        #expect(top[0].logitBits == "41c00000")
    }

    @Test func float32AndFloat16RowsAreReadAsStored() throws {
        let values: [Float] = [0.1, -2, 3.0000002, 3]
        var data32 = Data()
        for value in values { var bits = value.bitPattern.littleEndian; withUnsafeBytes(of: &bits) { data32.append(contentsOf: $0) } }
        let top32 = try MiMoStepEvidence.candidates(rowBytes: data32, dtype: "float32", count: 2)
        #expect(top32.map(\.tokenID) == [2, 3])
        #expect(top32[0].logit == 3.0000002)

        var data16 = Data()
        for value in values { var bits = Float16(value).bitPattern.littleEndian; withUnsafeBytes(of: &bits) { data16.append(contentsOf: $0) } }
        let top16 = try MiMoStepEvidence.candidates(rowBytes: data16, dtype: "float16", count: 2)
        // In float16 the two near values round to one: the lower token ID ranks first.
        #expect(top16.map(\.tokenID) == [2, 3])
        #expect(top16[0].logit == top16[1].logit)
    }

    @Test func malformedRowsAreRefused() {
        #expect(throws: (any Error).self) { try MiMoStepEvidence.candidates(rowBytes: Data([1, 2, 3]), dtype: "bfloat16") }
        #expect(throws: (any Error).self) { try MiMoStepEvidence.candidates(rowBytes: Data([1, 2, 3, 4]), dtype: "int32") }
        #expect(throws: (any Error).self) { try MiMoStepEvidence.candidates(rowBytes: Data(), dtype: "float32") }
    }

    @Test func runtimeLineUsesOnlyTheCharactersThePairDriverKeeps() throws {
        var row = [Float](repeating: 0, count: 64)
        row[3] = -1.5; row[5] = 2; row[9] = 1
        let step = MiMoStepEvidence(ordinal: 28, boundarySHA256: String(repeating: "ab", count: 32),
            rowSHA256: String(repeating: "cd", count: 32), rowDType: "bfloat16",
            top: try MiMoStepEvidence.candidates(rowBytes: Self.bfloat16Bytes(row), dtype: "bfloat16"))
        let line = step.line(rank: 1)
        #expect(line.hasPrefix(MiMoStepEvidence.linePrefix + " "))
        #expect(line.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || [32, 45, 61, 95].contains($0) })
        #expect(line == "darkbloom-mimo-step-v1 rank=1 i=28 boundary=abababababababab row=cdcdcdcdcdcdcdcd "
            + "dtype=bfloat16 top=5_40000000_9_3f800000_0_00000000_1_00000000")
    }
}
