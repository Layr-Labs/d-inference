// Copyright © 2026 Eigen Labs.
//
// WORKAROUND (Swift 6.3 / macOS 26, release builds): the generic
// `taskSleep(tolerance:clock:)` overload, inlined into long-lived
// task closures under -O, intermittently aborts the process with the
// Swift concurrency task allocator's "freed pointer was not the last
// allocation" (a `swift_task_dealloc` LIFO violation inside the sleep's
// own specialization; observed in the capacity-refresh monitor and the
// coordinator session loop during the v0.7.5 E2E gate — debug builds
// never crash, and the non-generic `Task.sleep(nanoseconds:)` codegen
// path is stable across repeated runs).
//
// EVERY sleep in ProviderCore routes through this shim; do not call
// `taskSleep()` directly. Revisit on a toolchain bump — if the
// runtime bug is fixed, this file shrinks to a deprecation note.

import Foundation

/// Suspend the current task for `duration` via the non-generic
/// nanoseconds entry point. Throws `CancellationError` on cancellation,
/// exactly like `taskSleep()`.
@inlinable
public func taskSleep(_ duration: Duration) async throws {
    let comps = duration.components
    let seconds = UInt64(max(0, comps.seconds))
    let attoseconds = UInt64(max(0, comps.attoseconds))
    let ns = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    let nanos = (ns.overflow ? UInt64.max : ns.partialValue)
        .addingReportingOverflow(attoseconds / 1_000_000_000)
    try await Task.sleep(nanoseconds: nanos.overflow ? UInt64.max : nanos.partialValue)
}
