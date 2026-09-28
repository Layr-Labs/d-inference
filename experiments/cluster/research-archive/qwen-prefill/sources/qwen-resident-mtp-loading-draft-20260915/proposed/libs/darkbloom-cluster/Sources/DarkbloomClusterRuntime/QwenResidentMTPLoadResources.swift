import Foundation

/// Optional additional-load ledger supplied to the existing target loader.
/// Actual array rounding is supplied by the native allocator, never by config.
struct QwenResidentMTPLoadResources {
    let tensorBounds: [Int]
    let reservedTensorBytes: Int
    let largestHostTensorBytes: Int

    init(placement: QwenResidentMTPPlacement, maximumBufferBytes: Int,
         bound: (Int) throws -> Int) throws {
        let values = placement.tensorsInReadOrder
        tensorBounds = try values.map { value in
            let rounded = try bound(value.byteCount)
            guard rounded >= value.byteCount, rounded <= maximumBufferBytes else {
                throw ProbeError("MTP tensor exceeds actual allocator/buffer limits")
            }
            return rounded
        }
        reservedTensorBytes = try QwenLongPrefillCheckedBytes.sum(tensorBounds)
        largestHostTensorBytes = values.map(\.byteCount).max() ?? 0
        guard largestHostTensorBytes > 0 else { throw ProbeError("Empty MTP load ledger") }
    }

    func pending(after completed: Int) throws -> (tensorBytes: Int, hostBytes: Int) {
        guard (0...tensorBounds.count).contains(completed) else {
            throw ProbeError("Invalid MTP load progress")
        }
        return (try QwenLongPrefillCheckedBytes.sum(Array(tensorBounds.dropFirst(completed))),
            completed < tensorBounds.count ? largestHostTensorBytes : 0)
    }
}
