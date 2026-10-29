import Foundation

extension DistributedLocalServer {
    func startLifetimeMonitor(_ target: DistributedLocalServerGeneration, deadline: UInt64) {
        guard generation === target else { return }
        lifetimeTask?.cancel()
        lifetimeTask = Task {
            while !Task.isCancelled {
                // The old timer cannot stop a replacement generation.
                guard generation === target else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                if now >= deadline { beginTeardown(drainUntil: nil); return }
                if [.starting, .serving].contains(phase),
                   target.session.status != .ready || target.session.httpSessionInvalid {
                    failed = true; beginTeardown(drainUntil: nil); return
                }
                if phase == .serving, target.session.httpSessionExhausted {
                    if replacementSessionFactory != nil {
                        beginQuotaRotation(target)
                    } else if target.pin == nil {
                        // Preserve the existing one-session default behavior.
                        beginTeardown(drainUntil: target.session.httpDrainOnExhaustion ? deadline : nil); return
                    }
                }
                if ![.starting, .serving, .rotating].contains(phase),
                   [.quarantined, .released].contains(target.session.status) {
                    beginTeardown(drainUntil: nil); return
                }
                do { try await Task.sleep(nanoseconds: min(deadline - now, 100_000_000)) }
                catch { return }
            }
        }
    }
}
