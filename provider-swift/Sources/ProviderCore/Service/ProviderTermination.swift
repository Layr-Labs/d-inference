import Foundation

/// AppKit and POSIX callbacks are just triggers. The running serve loop owns
/// shutdown, and a pre-start signal is retained until that loop is installed.
public actor ProviderTermination {
    public static let shared = ProviderTermination()
    private var handler: (@Sendable () async -> Bool)?
    private var requested = false
    public var terminationRequested: Bool { requested }
    private var task: Task<Bool, Never>?

    public static var timeoutSeconds: Int {
        guard let raw = ProcessInfo.processInfo.environment["DARKBLOOM_DRAIN_TIMEOUT_SECONDS"],
              let seconds = Int(raw), (1...3600).contains(seconds) else { return 600 }
        return seconds
    }

    public func install(_ handler: @escaping @Sendable () async -> Bool) {
        self.handler = handler
        if requested { Task { _ = await request() } }
    }

    public func request() async -> Bool {
        requested = true
        if let task { return await task.value }
        guard let handler else { return false }
        let task = Task { await handler() }
        self.task = task
        let result = await task.value
        self.task = nil
        return result
    }
}
