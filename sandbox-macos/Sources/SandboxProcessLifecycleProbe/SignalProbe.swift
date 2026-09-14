import Darwin
import Foundation
import SandboxRuntime

// Actual signals are tested in this disposable child, never in XCTest itself.
enum SignalProbe {
    static func run(mode: String, directory: URL) async -> Int32 {
        var info = stat()
        guard directory.lastPathComponent.hasPrefix("signal-cancellation-"),
              directory.resolvingSymlinksInPath().path == directory.path,
              lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else { return 78 }
        do {
            if mode == "--signal-restore" {
                _ = try await SandboxSignalCancellation.run { 42 }
                try Data().write(to: directory.appendingPathComponent("ready"), options: .withoutOverwriting)
                try await Task.sleep(for: .seconds(300))
                return 79
            }
            try await SandboxSignalCancellation.run {
                // A rejected nested watcher must not release the outer scope's
                // process-global ownership. A second attempt must also fail.
                for _ in 0..<2 {
                    do {
                        _ = try await SandboxSignalCancellation.run { 42 }
                        throw ProbeFailure.nestedScopeAccepted
                    } catch SandboxSignalCancellationError.alreadyInstalled { }
                }
                try Data().write(to: directory.appendingPathComponent("ready"), options: .withoutOverwriting)
                do {
                    try await Task.sleep(for: .seconds(300))
                } catch {
                    let cleanup = Task.detached {
                        try await Task.sleep(for: .milliseconds(200))
                        try Data("completed".utf8).write(to: directory.appendingPathComponent("cleanup"), options: .withoutOverwriting)
                    }
                    try await cleanup.value
                    throw error
                }
            }
            return 79
        } catch is CancellationError { return 0 }
        catch { return 78 }
    }

    private enum ProbeFailure: Error { case nestedScopeAccepted }
}
