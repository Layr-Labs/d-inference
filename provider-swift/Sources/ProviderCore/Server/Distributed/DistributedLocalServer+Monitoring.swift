import Foundation

extension DistributedLocalServer {
    /// Watches the serving generation. A session has no fixed lifetime and no
    /// request count: it serves until it is stopped or it fails. The monitor
    /// ends serving only when the session itself is no longer valid (a rank
    /// was lost, its rank lease lapsed, or it was quarantined or released).
    func startSessionMonitor(_ target: DistributedLocalServerGeneration) {
        guard generation === target else { return }
        monitorTask?.cancel()
        monitorTask = Task {
            while !Task.isCancelled {
                guard generation === target else { return }
                if [.starting, .serving].contains(phase),
                   target.session.status != .ready || target.session.httpSessionInvalid {
                    failed = true
                    if phase == .serving { recordSessionFailure(target) }
                    beginTeardown(drainUntil: nil); return
                }
                if ![.starting, .serving].contains(phase),
                   [.quarantined, .released].contains(target.session.status) {
                    beginTeardown(drainUntil: nil); return
                }
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { return }
            }
        }
    }
}
