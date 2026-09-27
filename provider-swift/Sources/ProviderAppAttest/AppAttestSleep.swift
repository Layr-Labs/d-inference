import Foundation

/// Keep App Attest off the generic Duration/Clock sleep specialization. In an
/// optimized multi-module provider it can abort in swift_task_dealloc when a
/// deadline task is cancelled (Swift issue #86204). ProviderCore/TaskSleep.swift
/// uses the same non-generic workaround; importing ProviderCore here would cycle.
func appAttestSleep(seconds: Double) async throws {
    let nanos = seconds * 1_000_000_000
    let bounded: UInt64
    if !(nanos > 0) {
        bounded = 0
    } else if nanos >= Double(UInt64.max) {
        bounded = UInt64.max
    } else {
        bounded = UInt64(nanos)
    }
    try await Task.sleep(nanoseconds: bounded)
}
