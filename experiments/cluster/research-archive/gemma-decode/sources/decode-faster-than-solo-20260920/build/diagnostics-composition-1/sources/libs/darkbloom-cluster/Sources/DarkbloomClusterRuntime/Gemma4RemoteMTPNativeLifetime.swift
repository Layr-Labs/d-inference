import Foundation

/// Retention only, not a second request/device/lease owner. A private benchmark
/// failure cannot restart. Its original process watchdog remains authoritative.
final class Gemma4RemoteMTPNativeLifetime {
    var group: Collective?
    var model: AnyObject?
    var assistant: AnyObject?
    var embedding: AnyObject?
    var session: Gemma4OwnedForwardSession?
    var target: Gemma4MTPPullTarget?
    var service: Gemma4MTPPullAssistant?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var failed: Gemma4RemoteMTPNativeLifetime?
    static func requireAvailable() throws {
        guard lock.withLock({ failed == nil }) else { throw ProbeError("Failed private remote MTP cohort cannot restart") }
    }
    func retainFailedUntilProcessExit() {
        Self.lock.withLock {
            // At most one cohort per private native process may fail. Retaining
            // this same object twice is harmless; replacing it is forbidden.
            precondition(Self.failed == nil || Self.failed === self)
            Self.failed = self
        }
    }
    func clearAfterSuccessfulFence() {
        target = nil; service = nil; session = nil
        model = nil; assistant = nil; embedding = nil
        group = nil
    }
}
