// ReachabilityMonitor: NWPathMonitor wrapper exposing a simple reachable flag
// so the connection loop can gate reconnect backoff on network availability.

import Foundation
import Network
#if canImport(os)
import os
#endif

// MARK: - Reachability

/// Lightweight wrapper over NWPathMonitor that tracks current network
/// reachability. The reconnect loop uses it to distinguish "the coordinator is
/// down" from "this box has no internet" — the latter is the dominant cause of
/// provider flap across the fleet and is an operator/network problem, not a
/// coordinator one. Surfacing it in reconnect telemetry makes that split
/// visible instead of every drop looking like a coordinator fault.
final class ReachabilityMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.darkbloom.reachability")
    private let lock = NSLock()
    private var _reachable = true

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self._reachable = (path.status == .satisfied)
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    var isReachable: Bool {
        lock.lock(); defer { lock.unlock() }
        return _reachable
    }

    func stop() { monitor.cancel() }
}

