import Foundation

/// The runner without an owned process, an output cap or a pause.
enum BoundedCommand {
    static func run(
        _ executablePath: String, _ arguments: [String], timeout: TimeInterval, outputLimit: Int,
        pauseBeforeCheck: (() -> Void)? = nil
    ) throws -> SecurityCommandResult {
        try SecurityCommandRunner.bounded(timeout: timeout).run(executablePath, arguments)
    }
}
