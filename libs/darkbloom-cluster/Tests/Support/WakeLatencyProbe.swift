import Dispatch
import Foundation

/// How late this host wakes a thread that waits for a deadline. A check that
/// bounds when waiting code runs (a renewal, a timer tick) runs the probe
/// beside that code, at the same quality of service: the probe waits on a
/// semaphore until a deadline every `periodNanoseconds` and keeps the worst
/// overshoot. The code may be late by that much, which depends on the host:
/// Blacksmith's VMs wake within a few milliseconds, a Darkbloom VM was 17 ms
/// late once.
final class WakeLatencyProbe: @unchecked Sendable {
    private let lock = NSLock(), sleeper = DispatchSemaphore(value: 0), stopped = DispatchSemaphore(value: 0)
    private var running = true, worst: UInt64 = 0, samples = 0

    init(qos: DispatchQoS, periodNanoseconds: UInt64 = 20_000_000) {
        DispatchQueue(label: "wake-latency.probe", qos: qos).async { [self] in
            while lock.withLock({ running }) {
                let deadline = DispatchTime.now().uptimeNanoseconds + periodNanoseconds
                _ = sleeper.wait(timeout: .init(uptimeNanoseconds: deadline))
                let woke = DispatchTime.now().uptimeNanoseconds, late = woke > deadline ? woke - deadline : 0
                lock.withLock { worst = max(worst, late); samples += 1 }
            }
            stopped.signal()
        }
    }

    /// What the probe saw: its worst overshoot and its number of waits.
    struct Reading: Sendable {
        let worst: UInt64, samples: Int
        /// How late the code under check may wake: the worst overshoot with
        /// 5 ms to spare, and never less than the 15 ms a fast host gets.
        var allowedLateness: UInt64 { max(15_000_000, worst + 5_000_000) }
    }

    /// Stops the probe and returns what it saw.
    func stop() -> Reading {
        lock.withLock { running = false }
        stopped.wait()
        return lock.withLock { Reading(worst: worst, samples: samples) }
    }
}
