import Foundation
import NIOCore

/// One close callback per connection, not one retained Task per request on a
/// long-lived keep-alive connection. Entries leave the registry on close.
final class LocalHTTPConnectionCancellationRegistry: @unchecked Sendable {
    static let shared = LocalHTTPConnectionCancellationRegistry()
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: LocalHTTPConnectionCancellation] = [:]
    var connectionCount: Int { lock.withLock { connections.count } }

    func connection(for channel: any Channel) -> LocalHTTPConnectionCancellation {
        let id = ObjectIdentifier(channel)
        let (state, created) = lock.withLock {
            if let state = connections[id] { return (state, false) }
            let state = LocalHTTPConnectionCancellation(channel: channel)
            connections[id] = state
            return (state, true)
        }
        if created {
            let identity = state.identity
            channel.closeFuture.whenComplete { [weak self] _ in
                self?.closed(id: id, identity: identity)
            }
        }
        return state
    }

    private func closed(id: ObjectIdentifier, identity: UUID) {
        let state: LocalHTTPConnectionCancellation? = lock.withLock {
            guard connections[id]?.identity == identity else { return nil }
            return connections.removeValue(forKey: id)
        }
        state?.cancelAll()
    }
}

final class LocalHTTPConnectionCancellation: @unchecked Sendable {
    let identity = UUID()
    // Retain the channel until close: its ObjectIdentifier cannot be reused
    // by another connection before this registry entry is removed.
    private let channel: any Channel
    private let lock = NSLock()
    private var closed = false
    private var requests: [UUID: WeakScope] = [:]
    var requestCount: Int { lock.withLock { requests.count } }

    private final class WeakScope {
        weak var value: LocalRequestCancellationScope?
        init(_ value: LocalRequestCancellationScope) { self.value = value }
    }

    init(channel: any Channel) { self.channel = channel }

    func makeScope() -> LocalRequestCancellationScope {
        let id = UUID()
        let scope = LocalRequestCancellationScope { [weak self] in
            self?.remove(id)
        }
        let cancelNow = lock.withLock {
            if closed { return true }
            requests[id] = WeakScope(scope)
            return false
        }
        if cancelNow { scope.cancel() }
        return scope
    }

    private func remove(_ id: UUID) { lock.withLock { _ = requests.removeValue(forKey: id) } }

    func cancelAll() {
        let active: [LocalRequestCancellationScope] = lock.withLock {
            closed = true
            let active = requests.values.compactMap(\.value)
            requests.removeAll()
            return active
        }
        for scope in active { scope.cancel() }
    }
}
