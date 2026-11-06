import Foundation

/// Retains late startup results and keeps the member control connection alive
/// until its existing terminal work has returned. This owns no native process.
actor ProtectedLocalStartLifecycle {
    private let closeControl: @Sendable () -> Task<Void, Never>
    private var controlCleanup: Task<Void, Never>?
    private var scope: NativePairLocalStart?
    private var server: DistributedLocalServer?
    private var stopping = false

    init(closeControl: @escaping @Sendable () -> Task<Void, Never>) { self.closeControl = closeControl }
    func install(_ value: NativePairLocalStart) throws {
        guard scope == nil else { throw NativePairMemberError.inactive }
        scope = value
        if stopping { value.cancel(); throw CancellationError() }
    }
    func install(_ value: DistributedLocalServer) async throws {
        guard server == nil else { throw NativePairMemberError.inactive }
        server = value
        if stopping {
            _ = await value.stop(until: Self.deadline())
            throw CancellationError()
        }
    }
    func stop() async {
        stopping = true
        if controlCleanup == nil { controlCleanup = closeControl() }
        scope?.cancel()
        if let server { _ = await server.stop(until: Self.deadline()) }
    }
    func finish() async -> DistributedLocalServerStatus? {
        await stop()
        if let scope { await scope.waitUntilClosed() }
        if let controlCleanup { await controlCleanup.value }
        // The process/control join is not a request or HTTP-release substitute.
        if let server { return await server.stop(until: Self.deadline()) }
        return nil
    }
    private static func deadline() -> UInt64 { DispatchTime.now().uptimeNanoseconds + 15_000_000_000 }
}
