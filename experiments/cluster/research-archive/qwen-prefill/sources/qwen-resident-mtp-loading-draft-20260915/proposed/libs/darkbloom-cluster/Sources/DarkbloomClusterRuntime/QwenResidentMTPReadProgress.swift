import Foundation

/// The selected reader advances only after an evaluated allocation passed its
/// descriptor/ownership checks. Failure permanently refuses another read.
struct QwenResidentMTPReadProgress {
    let placement: QwenResidentMTPPlacement
    let resources: QwenResidentMTPLoadResources
    private(set) var completed = 0
    private(set) var failed = false

    func entry(name: String, shape: [Int], packed: Bool) throws -> QwenDenseCanonicalTensor {
        let entries = placement.tensorsInReadOrder
        guard !failed, entries.indices.contains(completed), entries[completed].name == name,
              entries[completed].shape == shape, (entries[completed].sourceDType == "U32") == packed else {
            throw ProbeError("MTP read differs from its complete ordered inventory")
        }
        return entries[completed]
    }

    mutating func accept(copiedBytes: Int) throws {
        let entries = placement.tensorsInReadOrder
        guard !failed, entries.indices.contains(completed), copiedBytes == entries[completed].byteCount else {
            throw ProbeError("MTP completed read differs from its admitted byte count")
        }
        completed += 1
    }

    mutating func poison() { failed = true }

    func pending() throws -> (tensorBytes: Int, hostBytes: Int) {
        guard !failed else { throw ProbeError("MTP materializer is poisoned") }
        return try resources.pending(after: completed)
    }

    func requireComplete() throws {
        guard !failed, completed == placement.tensorsInReadOrder.count else {
            throw ProbeError("MTP selected loading did not complete")
        }
    }
}
