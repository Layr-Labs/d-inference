import Foundation

@main struct UnreadStagingChecks {
    static func main() throws {
        var groups = 0
        func require(_ value: Bool) { precondition(value) }
        func bounds(_ logical: [Int], _ allocation: [Int], _ completed: Int,
                    _ pending: Int? = nil, _ loading: Bool = true) throws -> Gemma4BenchmarkUnreadStaging.Bounds {
            try Gemma4BenchmarkUnreadStaging.bounds(logicalBytes: logical.lazy.map { $0 },
                allocationBounds: allocation, completed: completed, pending: pending, loading: loading)
        }
        func refused(_ body: () throws -> Void) {
            do { try body(); preconditionFailure("Invalid staging accepted") }
            catch is Gemma4BenchmarkUnreadStaging.Failure { }
            catch { preconditionFailure("Unexpected error: \(error)") }
        }
        let logical = [369_098_752, 512, 126_877_696, 5_632]
        let allocated = [369_131_519, 767, 126_910_463, 8_191]
        let initial = try bounds(logical, allocated, 0)
        require(initial == .init(hostBytes: 369_098_752, nativeCopyBytes: 369_131_519)); groups += 1
        // Beginning even the largest read does not retire its staging.
        require(try bounds(logical, allocated, 0, 0) == initial); groups += 1
        let unread = try bounds(logical, allocated, 1)
        require(unread == .init(hostBytes: 126_877_696, nativeCopyBytes: 126_910_463))
        require(try bounds(logical, allocated, 1, 1) == unread); groups += 1
        // Pending must include the last large tensor until original completion.
        require(try bounds(logical, allocated, 2, 2) == unread)
        require(try bounds(logical, allocated, 3) == .init(hostBytes: 5_632, nativeCopyBytes: 8_191)); groups += 1
        require(try bounds(logical, allocated, 4) == .init(hostBytes: 0, nativeCopyBytes: 0))
        require(try bounds(logical, allocated, 4, nil, false) == .init(hostBytes: 0, nativeCopyBytes: 0)); groups += 1
        for (completed, pending, loading) in [(-1, nil, true), (5, nil, true), (0, 1, true), (4, 4, true), (1, nil, false)] as [(Int,Int?,Bool)] {
            refused { _ = try bounds(logical, allocated, completed, pending, loading) }
        }; groups += 1
        refused { _ = try bounds([], [], 0) }
        refused { _ = try bounds([1], [], 0) }
        refused { _ = try bounds([2], [1], 0) }
        refused { _ = try bounds([0], [1], 0) }; groups += 1
        // Never assume the allocator bound follows logical-size ordering.
        require(try bounds([100,99], [110,200], 0) == .init(hostBytes: 100, nativeCopyBytes: 200))
        require(try bounds([100,99], [110,200], 1) == .init(hostBytes: 99, nativeCopyBytes: 200)); groups += 1
        print("{\"schema\":\"gemma4_unread_staging_checks_v1\",\"passed\":true,\"groups\":\(groups),\"nativeExecuted\":false}")
    }
}
