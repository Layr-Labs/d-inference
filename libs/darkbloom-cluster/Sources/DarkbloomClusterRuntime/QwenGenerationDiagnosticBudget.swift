import Foundation

/// Named incremental capture storage, separate from the existing request
/// state/fusion allowance. These are not whole-process peak bounds.
struct QwenGenerationDiagnosticBudget: Encodable {
    let rank: Int
    let vocabularySize: Int
    let activationDType: String
    let logicalRowBytes: Int
    let float32RowBytes: Int
    let extraHostBytes: Int
    let extraNativeBytes: Int
    let originalRequestReservedBytes: Int

    static func derive(rank: Int, vocabularySize: Int, activationDType: String,
                       requestReservedBytes: Int, bound: (Int) throws -> Int) throws -> Self {
        guard (0...1).contains(rank), (1...262_144).contains(vocabularySize),
              ["float16", "bfloat16", "float32"].contains(activationDType),
              requestReservedBytes > 0 else { throw ProbeError("Invalid generation diagnostic capture budget") }
        let sum = QwenLongPrefillCheckedBytes.sum, product = QwenLongPrefillCheckedBytes.product
        let row = rank == 1 ? try product([vocabularySize, activationDType == "float32" ? 4 : 2]) : 0
        let floating = rank == 1 ? try product([vocabularySize, 4]) : 0
        var native = 0
        if rank == 1 {
            // Bound each array independently, including the final native row
            // whose lifetime extends through its complete CPU capture.
            let rowBound = try bound(row), floatingBound = try bound(floating)
            guard rowBound >= row, floatingBound >= floating else {
                throw ProbeError("Generation diagnostic allocator bound is smaller than its array")
            }
            native = try sum([rowBound, floatingBound])
        }
        return .init(rank: rank, vocabularySize: vocabularySize, activationDType: activationDType,
            logicalRowBytes: row, float32RowBytes: floating, extraHostBytes: try sum([row, floating]),
            extraNativeBytes: native, originalRequestReservedBytes: requestReservedBytes)
    }

    func requiredActualFreeBytes(minimum: Int, headroom: Int) throws -> Int {
        guard minimum > 0, headroom > 0 else { throw ProbeError("Invalid diagnostic actual-free policy") }
        return max(minimum, try QwenLongPrefillCheckedBytes.sum([
            originalRequestReservedBytes, extraHostBytes, extraNativeBytes, headroom,
        ]))
    }

    func requiredAllocatorBytes(active: Int, cache: Int, headroom: Int) throws -> Int {
        guard active >= 0, cache >= 0, headroom > 0 else { throw ProbeError("Invalid diagnostic allocator observation") }
        return try QwenLongPrefillCheckedBytes.sum([
            active, cache, originalRequestReservedBytes, extraNativeBytes, headroom,
        ])
    }
}
