import MLX
import Testing

@Suite(.serialized)
struct Gemma4BatchDecodeTests {
    @Test func registeredQuantizationRowsPreserveLogitsAndEveryLiveKVValue() throws {
        try Device.withDefaultDevice(.cpu) {
            try MLX.withError { error in
                for bits in [4, 8] {
                    for rows in [2, 4, 8] {
                        for embeddings in [false, true] {
                            let result = try runGemmaBatchCase(bits: bits, rows: rows, dtype: .bfloat16,
                                embeddings: embeddings, exact: true, check: { try error.check() })
                            #expect(result.mismatches.isEmpty,
                                "bits=\(bits) rows=\(rows) embeddings=\(embeddings): \(result.mismatches)")
                        }
                    }
                }
            }
        }
    }
}
