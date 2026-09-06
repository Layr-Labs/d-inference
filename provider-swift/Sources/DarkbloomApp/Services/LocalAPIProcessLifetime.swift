import AppKit
import Foundation

/// Immutable, thread-safe cancellation handle for the foreground child. Leaving
/// the Local API screen keeps Chat usable; application termination cancels the
/// runner synchronously so the local child is not intentionally orphaned.
final class LocalAPIProcessLifetime: @unchecked Sendable {
    private let task: Task<Void, Never>
    private let observer: any NSObjectProtocol

    init(task: Task<Void, Never>) {
        self.task = task
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in task.cancel() }
    }

    deinit {
        NotificationCenter.default.removeObserver(observer)
        task.cancel()
    }
}
