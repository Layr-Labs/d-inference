import Foundation

/// Per-path leases on durable checkpoint files, shared by every store in the
/// process. Stage reads share a file; its writer, duplicate validation, scans,
/// maintenance and retirement hold it exclusively. Requests are granted in
/// arrival order, and a queued exclusive request also holds back every later
/// one, so a stream of overlapping readers never starves a writer.
final class SSDCheckpointFileCoordinator: @unchecked Sendable {
    static let shared = SSDCheckpointFileCoordinator()

    enum Mode { case shared, exclusive }

    fileprivate typealias Continuation = CheckedContinuation<Void, any Error>

    final class Access: @unchecked Sendable {
        fileprivate enum State {
            case idle
            case waiting(Continuation)
            case active
            case finished
        }

        fileprivate let coordinator: SSDCheckpointFileCoordinator
        fileprivate let path: String
        // Guarded by the coordinator's lock; changes only by upgrade/downgrade.
        fileprivate var mode: Mode
        fileprivate var state = State.idle

        fileprivate init(coordinator: SSDCheckpointFileCoordinator, path: String, mode: Mode) {
            self.coordinator = coordinator
            self.path = path
            self.mode = mode
        }

        func acquire() async throws {
            do {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        coordinator.enqueue(self, continuation: continuation)
                    }
                    try Task.checkCancellation()
                } onCancel: {
                    self.cancel()
                }
            } catch {
                release()
                throw error
            }
        }

        func cancel() { coordinator.cancel(self) }
        func release() { coordinator.release(self) }

        /// Makes the only holder of a shared lease exclusive, without waiting.
        /// Refused while another holder or any queued request exists, so a
        /// mutation never moves a concurrent reader's file identity and never
        /// overtakes a waiting writer.
        func tryUpgrade() -> Bool { coordinator.tryUpgrade(self) }

        /// Returns an exclusive holder to shared access and admits the shared
        /// requests that queued behind it.
        func downgrade() { coordinator.downgrade(self) }
    }

    private struct FileLeases {
        /// All shared, or one exclusive holder.
        var holders: [Access] = []
        /// Arrival order.
        var waiters: [Access] = []
    }

    private let lock = NSLock()
    private var files: [String: FileLeases] = [:]

    func makeAccess(to url: URL, mode: Mode = .exclusive) -> Access {
        Access(coordinator: self, path: Self.coordinationPath(for: url), mode: mode)
    }

    /// Maintenance must never wait for a writer while holding the epoch or
    /// disk-budget lock: writers consult those owners before releasing a file.
    /// A file with any holder or queued request, a reader included, is
    /// skipped; unrelated entries remain eligible for eviction.
    func tryAcquire(to url: URL) -> Access? {
        let access = makeAccess(to: url)
        return lock.withLock {
            guard files[access.path] == nil else { return nil }
            access.state = .active
            files[access.path] = FileLeases(holders: [access])
            return access
        }
    }

    var trackedFileCount: Int { lock.withLock { files.count } }

    /// Requests queued behind the current holders.
    func pendingCount(for url: URL) -> Int {
        let path = Self.coordinationPath(for: url)
        return lock.withLock { files[path]?.waiters.count ?? 0 }
    }

    private static func coordinationPath(for url: URL) -> String {
        var components: [Substring] = []
        for component in url.path.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                if components.isEmpty && (component == "tmp" || component == "var") {
                    components.append("private")
                }
                components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    private static func admits(_ mode: Mode, holders: [Access]) -> Bool {
        switch mode {
        case .exclusive: holders.isEmpty
        case .shared: holders.first?.mode != .exclusive
        }
    }

    /// Grants queued requests in order until one conflicts with the holders;
    /// that one keeps everything behind it waiting. Caller holds `lock`.
    private static func admitWaiters(_ leases: inout FileLeases) -> [Continuation] {
        var admitted: [Continuation] = []
        while let next = leases.waiters.first, admits(next.mode, holders: leases.holders) {
            guard case .waiting(let continuation) = next.state else { preconditionFailure() }
            leases.waiters.removeFirst()
            next.state = .active
            leases.holders.append(next)
            admitted.append(continuation)
        }
        return admitted
    }

    private func store(_ leases: FileLeases, at path: String) {
        files[path] = leases.holders.isEmpty && leases.waiters.isEmpty ? nil : leases
    }

    private func enqueue(_ access: Access, continuation: Continuation) {
        let immediate = lock.withLock { () -> Result<Void, any Error>? in
            guard case .idle = access.state else { return .failure(CancellationError()) }
            var leases = files[access.path] ?? FileLeases()
            defer { files[access.path] = leases }
            if leases.waiters.isEmpty, Self.admits(access.mode, holders: leases.holders) {
                access.state = .active
                leases.holders.append(access)
                return .success(())
            }
            access.state = .waiting(continuation)
            leases.waiters.append(access)
            return nil
        }
        if let immediate { continuation.resume(with: immediate) }
    }

    private func cancel(_ access: Access) {
        let (cancelled, admitted) = lock.withLock { () -> (Continuation?, [Continuation]) in
            switch access.state {
            case .idle:
                access.state = .finished
            case .waiting(let continuation):
                guard var leases = files[access.path] else { preconditionFailure() }
                leases.waiters.removeAll { $0 === access }
                access.state = .finished
                // A withdrawn exclusive request no longer holds back the
                // shared requests queued behind it.
                let admitted = Self.admitWaiters(&leases)
                store(leases, at: access.path)
                return (continuation, admitted)
            case .active, .finished:
                break
            }
            return (nil, [])
        }
        cancelled?.resume(throwing: CancellationError())
        for continuation in admitted { continuation.resume() }
    }

    private func release(_ access: Access) {
        let admitted = lock.withLock { () -> [Continuation] in
            guard case .active = access.state else { return [] }
            access.state = .finished
            guard var leases = files[access.path],
                let index = leases.holders.firstIndex(where: { $0 === access })
            else { preconditionFailure() }
            leases.holders.remove(at: index)
            let admitted = Self.admitWaiters(&leases)
            store(leases, at: access.path)
            return admitted
        }
        for continuation in admitted { continuation.resume() }
    }

    private func tryUpgrade(_ access: Access) -> Bool {
        lock.withLock {
            guard case .active = access.state, access.mode == .shared,
                let leases = files[access.path], leases.waiters.isEmpty,
                leases.holders.count == 1, leases.holders[0] === access
            else { return false }
            access.mode = .exclusive
            return true
        }
    }

    private func downgrade(_ access: Access) {
        let admitted = lock.withLock { () -> [Continuation] in
            guard case .active = access.state, access.mode == .exclusive,
                var leases = files[access.path] else { return [] }
            access.mode = .shared
            let admitted = Self.admitWaiters(&leases)
            store(leases, at: access.path)
            return admitted
        }
        for continuation in admitted { continuation.resume() }
    }
}
