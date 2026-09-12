import Foundation

final class SSDCheckpointFileCoordinator: @unchecked Sendable {
    static let shared = SSDCheckpointFileCoordinator()

    final class Access: @unchecked Sendable {
        fileprivate enum State {
            case idle
            case waiting(CheckedContinuation<Void, any Error>)
            case active
            case finished
        }

        fileprivate let coordinator: SSDCheckpointFileCoordinator
        fileprivate let path: String
        fileprivate var state = State.idle

        fileprivate init(coordinator: SSDCheckpointFileCoordinator, path: String) {
            self.coordinator = coordinator
            self.path = path
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
    }

    private let lock = NSLock()
    private var files: [String: [Access]] = [:]

    func makeAccess(to url: URL) -> Access {
        Access(coordinator: self, path: Self.coordinationPath(for: url))
    }

    var trackedFileCount: Int { lock.withLock { files.count } }

    func pendingCount(for url: URL) -> Int {
        let path = Self.coordinationPath(for: url)
        return lock.withLock { max(0, (files[path]?.count ?? 0) - 1) }
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

    private func enqueue(_ access: Access, continuation: CheckedContinuation<Void, any Error>) {
        let immediate = lock.withLock { () -> Result<Void, any Error>? in
            guard case .idle = access.state else { return .failure(CancellationError()) }
            if files[access.path] == nil {
                access.state = .active
                files[access.path] = [access]
                return .success(())
            }
            access.state = .waiting(continuation)
            files[access.path, default: []].append(access)
            return nil
        }
        if let immediate { continuation.resume(with: immediate) }
    }

    private func cancel(_ access: Access) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            switch access.state {
            case .idle:
                access.state = .finished
            case .waiting(let continuation):
                files[access.path]?.removeAll { $0 === access }
                access.state = .finished
                return continuation
            case .active, .finished:
                break
            }
            return nil
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func release(_ access: Access) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            guard case .active = access.state else { return nil }
            access.state = .finished
            guard var queue = files.removeValue(forKey: access.path) else { return nil }
            precondition(queue.first === access)
            queue.removeFirst()
            guard let next = queue.first else { return nil }
            guard case .waiting(let continuation) = next.state else { preconditionFailure() }
            next.state = .active
            files[access.path] = queue
            return continuation
        }
        continuation?.resume()
    }
}
