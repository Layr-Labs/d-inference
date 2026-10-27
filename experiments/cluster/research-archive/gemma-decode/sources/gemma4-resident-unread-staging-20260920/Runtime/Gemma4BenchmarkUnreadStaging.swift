/// Future loader staging for the exact unread suffix. The caller is the existing
/// ordered load owner; this scalar calculation never advances its frontier.
/// Lazy views of existing metadata avoid a new retained allocation table.
enum Gemma4BenchmarkUnreadStaging {
    enum Failure: Error { case invalidInventory, invalidFrontier }
    struct Bounds: Equatable { let hostBytes: Int, nativeCopyBytes: Int }

    static func bounds<L: Collection, A: Collection>(
        logicalBytes: L, allocationBounds: A, completed: Int, pending: Int?, loading: Bool
    ) throws -> Bounds where L.Element == Int, A.Element == Int {
        guard !logicalBytes.isEmpty, logicalBytes.count == allocationBounds.count else {
            throw Failure.invalidInventory
        }
        let count = logicalBytes.count
        guard (0...count).contains(completed),
              pending == nil || (pending == completed && completed < count),
              loading || (completed == count && pending == nil) else {
            throw Failure.invalidFrontier
        }
        var host = 0, copy = 0
        for (logical, allocated) in zip(logicalBytes.dropFirst(completed), allocationBounds.dropFirst(completed)) {
            guard logical > 0, allocated >= logical else { throw Failure.invalidInventory }
            host = max(host, logical)
            copy = max(copy, allocated)
        }
        return .init(hostBytes: host, nativeCopyBytes: copy)
    }
}
