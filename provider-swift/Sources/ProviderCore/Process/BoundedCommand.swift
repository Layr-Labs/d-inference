import Darwin
import Foundation

/// The runner without an owned process, an output cap, the system-call hooks or a pause.
enum BoundedCommand {
    static func run(
        _ executablePath: String, _ arguments: [String], timeout: TimeInterval, outputLimit: Int,
        hooks: BoundedCommandHooks = .live, pauseBeforeCheck: (() -> Void)? = nil
    ) throws -> SecurityCommandResult {
        try SecurityCommandRunner.bounded(timeout: timeout).run(executablePath, arguments)
    }
}

struct BoundedCommandHooks: @unchecked Sendable {
    var waitForExit: @Sendable (pid_t) -> (result: Int32, error: Int32)
    var reap: @Sendable (pid_t, Int32) -> (pid: pid_t, raw: Int32, error: Int32)
    var signal: @Sendable (pid_t) -> Void
    var failingSetupStep: Int?

    static let live = BoundedCommandHooks(
        waitForExit: { _ in (0, 0) },
        reap: { pid, _ in (pid, 0, 0) },
        signal: { _ in },
        failingSetupStep: nil)
}
