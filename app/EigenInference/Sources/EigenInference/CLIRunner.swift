/// CLIRunner — Centralized utility for running eigeninference-provider subcommands.
///
/// Every feature in the app (doctor, wallet, earnings, enroll, models, status)
/// shells out to the Rust `eigeninference-provider` binary. This class centralizes
/// Process management, binary resolution, and output capture.

import Foundation

/// Result of a CLI command execution.
struct CLIResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var success: Bool { exitCode == 0 }

    /// Combined stdout + stderr output.
    var output: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Runs eigeninference-provider subcommands and captures output.
final class CLIRunner {

    /// Resolve the path to the eigeninference-provider binary.
    ///
    /// Searches in order:
    ///   1. `~/.eigeninference/bin/eigeninference-provider` (shared install, preferred)
    ///   2. Inside the app bundle (fallback for first-run before CLI install)
    ///   3. PATH lookup
    static func resolveBinaryPath() -> String? {
        let fm = FileManager.default

        // 1. ~/.eigeninference/bin/eigeninference-provider (shared with CLI — single source of truth)
        let home = fm.homeDirectoryForCurrentUser
        let homeBin = home.appendingPathComponent(".eigeninference/bin/eigeninference-provider").path
        if fm.isExecutableFile(atPath: homeBin) {
            return homeBin
        }

        // 2. Inside app bundle (fallback)
        if let bundlePath = Bundle.main.executablePath {
            let bundleDir = (bundlePath as NSString).deletingLastPathComponent
            let adjacent = (bundleDir as NSString).appendingPathComponent("eigeninference-provider")
            if fm.isExecutableFile(atPath: adjacent) {
                return adjacent
            }
        }

        // 3. PATH lookup
        let whichProcess = Process()
        let whichPipe = Pipe()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["eigeninference-provider"]
        whichProcess.standardOutput = whichPipe
        whichProcess.standardError = Pipe()
        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
            if whichProcess.terminationStatus == 0 {
                let data = whichPipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    return path
                }
            }
        } catch {}

        return nil
    }

    /// Run a eigeninference-provider subcommand and wait for completion.
    ///
    /// - Parameter args: Arguments to pass (e.g., `["doctor", "--coordinator", url]`)
    /// - Returns: CLIResult with exit code, stdout, and stderr
    static func run(_ args: [String]) async throws -> CLIResult {
        guard let binaryPath = resolveBinaryPath() else {
            return CLIResult(
                exitCode: -1,
                stdout: "",
                stderr: "eigeninference-provider binary not found"
            )
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: binaryPath)
                proc.arguments = args

                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe

                // Inherit the user's PATH for finding python, vllm-mlx, etc.
                var env = ProcessInfo.processInfo.environment
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let extraPaths = [
                    "\(home)/.eigeninference/bin",
                    "\(home)/.eigeninference/python/bin",
                    "/opt/homebrew/bin",
                    "/usr/local/bin",
                ]
                let existingPath = env["PATH"] ?? "/usr/bin:/bin"
                env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
                proc.environment = env

                do {
                    try proc.run()
                    proc.waitUntilExit()

                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

                    let result = CLIResult(
                        exitCode: proc.terminationStatus,
                        stdout: String(data: outData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                        stderr: String(data: errData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Run a subcommand with streaming line-by-line output.
    ///
    /// - Parameters:
    ///   - args: Arguments for eigeninference-provider
    ///   - onLine: Called for each line of combined stdout/stderr output
    /// - Returns: The process for lifecycle management (caller should retain)
    static func stream(
        _ args: [String],
        onLine: @escaping @Sendable (String) -> Void
    ) throws -> Process {
        guard let binaryPath = resolveBinaryPath() else {
            throw CLIError.binaryNotFound
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPaths = ["\(home)/.eigeninference/bin", "\(home)/.eigeninference/python/bin", "/opt/homebrew/bin"]
        let existingPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
        proc.environment = env

        let handleData: @Sendable (FileHandle) -> Void = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }
            for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                onLine(line)
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = handleData
        errPipe.fileHandleForReading.readabilityHandler = handleData

        try proc.run()
        return proc
    }

    /// Run a simple shell command (not eigeninference-provider).
    static func shell(_ command: String) async -> CLIResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
                proc.arguments = ["-c", command]

                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe

                do {
                    try proc.run()
                    proc.waitUntilExit()

                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

                    continuation.resume(returning: CLIResult(
                        exitCode: proc.terminationStatus,
                        stdout: String(data: outData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                        stderr: String(data: errData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    ))
                } catch {
                    continuation.resume(returning: CLIResult(
                        exitCode: -1, stdout: "", stderr: error.localizedDescription
                    ))
                }
            }
        }
    }
}

enum CLIError: LocalizedError {
    case binaryNotFound

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "eigeninference-provider binary not found. Run the installer first."
        }
    }
}
