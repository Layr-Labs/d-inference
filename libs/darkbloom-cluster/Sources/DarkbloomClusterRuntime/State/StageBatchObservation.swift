import Foundation

/// Bounded observations of completed native work on one serial stage owner.
/// This never schedules work or reads request content. Capacity is an admission
/// ceiling; only completedDecode establishes an observed native row width.
final class StageBatchObservation {
    struct Memory {
        let backend: String
        let capacity: Int
        let reserved: Int
        let inUse: Int
        /// Actual paged slab backing; nil when the backend has no public metric.
        let materialized: Int?
        let boundRows: Int
        let drained: Bool
    }

    private let rank: Int
    private let scope: UUID
    private let capacity: Int
    private var maximumWidth = 0
    private var began = false
    private var prefilled = false
    private var ended = false

    init(rank: Int, scope: UUID, capacity: Int) {
        self.rank = rank; self.scope = scope; self.capacity = capacity
    }

    func started(memory: @autoclosure () -> Memory) -> [String] {
        guard !began, !ended else { return [] }
        began = true
        return [memoryLine("begin", memory())]
    }

    func completedPrefill(memory: @autoclosure () -> Memory) -> [String] {
        guard began, !prefilled, !ended else { return [] }
        prefilled = true
        return [memoryLine("prefill", memory())]
    }

    func completedDecode(width: Int, memory: @autoclosure () -> Memory) -> [String] {
        guard began, !ended, (1...8).contains(capacity),
              width > maximumWidth, width <= capacity else { return [] }
        maximumWidth = width
        return ["darkbloom-stage-batch-decode-v1 \(identity) width=\(width) capacity=\(capacity)",
                memoryLine("decode", memory())]
    }

    func finished(success: Bool, memory: @autoclosure () -> Memory) -> [String] {
        guard began, !ended else { return [] }
        ended = true
        // A failed loop is never called idle, even if its cleanup drained.
        return [memoryLine(success ? "retired" : "failed", memory())]
    }

    private var identity: String { "rank=\(rank) scope=\(scope.uuidString.lowercased())" }

    private func memoryLine(_ phase: String, _ value: Memory) -> String {
        "darkbloom-stage-batch-memory-v1 \(identity) phase=\(phase) backend=\(value.backend)"
            + " capacity=\(value.capacity) reserved=\(value.reserved) in_use=\(value.inUse)"
            + " materialized=\(value.materialized.map(String.init) ?? "unavailable")"
            + " bound_rows=\(value.boundRows) drained=\(value.drained ? 1 : 0)"
    }
}
