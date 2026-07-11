import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum BoundedProcess {
    enum Failure: Error, LocalizedError, CustomStringConvertible {
        case exited(status: Int32)
        case signalled(signal: Int32)
        case timedOut(seconds: TimeInterval)
        case wouldNotTerminate

        var description: String {
            switch self {
            case .exited(let status):
                return "process exited \(status)"
            case .signalled(let signal):
                return "process terminated by signal \(signal)"
            case .timedOut(let seconds):
                return "process exceeded \(seconds) seconds"
            case .wouldNotTerminate:
                return "process did not terminate after SIGKILL"
            }
        }

        var errorDescription: String? { description }
    }

    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(
                environment,
                uniquingKeysWith: { _, override in override })
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        guard waitForExit(process, timeout: timeout) else {
            process.terminate()
            if !waitForExit(process, timeout: 2) {
                forceKill(process)
                guard waitForExit(process, timeout: 2) else {
                    throw Failure.wouldNotTerminate
                }
            }
            process.waitUntilExit()
            throw Failure.timedOut(seconds: timeout)
        }
        process.waitUntilExit()

        guard process.terminationReason == .exit else {
            throw Failure.signalled(signal: process.terminationStatus)
        }
        guard process.terminationStatus == 0 else {
            throw Failure.exited(status: process.terminationStatus)
        }
    }

    private static func waitForExit(
        _ process: Process,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while process.isRunning,
              ProcessInfo.processInfo.systemUptime < deadline
        {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !process.isRunning
    }

    private static func forceKill(_ process: Process) {
        #if canImport(Darwin)
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        #else
        process.terminate()
        #endif
    }
}
