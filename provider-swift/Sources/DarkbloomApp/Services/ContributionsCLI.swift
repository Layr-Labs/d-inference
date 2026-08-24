import Foundation
import ProviderCoreFoundation

typealias ContributionsEarningsPayload = ProviderAccountEarningsReport

protocol ContributionsCLIRunning: Sendable {
    func fetchEarnings() async throws -> ContributionsEarningsPayload
}

enum ContributionsCLIError: Error, Equatable, LocalizedError, Sendable {
    case cliNotFound
    case exited(Int32, message: String)
    case timedOut(command: String)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "The Darkbloom provider CLI is not installed, so earnings cannot be fetched."
        case .exited(let status, let message):
            message.isEmpty ? "The earnings command failed (exit \(status))." : message
        case .timedOut(let command):
            "The command `darkbloom \(command)` did not finish in time."
        case .invalidOutput(let detail):
            "The provider CLI returned unreadable earnings data (\(detail))."
        }
    }
}

private struct ContributionsCLIResult: Sendable, Equatable {
    var exitStatus: Int32
    var stdout: String
}

struct ProcessContributionsCLI: ContributionsCLIRunning {
    private let locator: any DarkbloomCLILocating
    private let timeout: Duration

    init(
        locator: any DarkbloomCLILocating = SystemDarkbloomCLILocator(),
        timeout: Duration = .seconds(30)
    ) {
        self.locator = locator
        self.timeout = timeout
    }

    func fetchEarnings() async throws -> ContributionsEarningsPayload {
        let result = try await invoke(arguments: ["earnings", "--json"])
        guard !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = result.stdout.data(using: .utf8)
        else {
            throw ContributionsCLIError.invalidOutput("empty stdout")
        }
        do {
            return try JSONDecoder().decode(ContributionsEarningsPayload.self, from: data)
        } catch {
            throw ContributionsCLIError.invalidOutput("\(error)")
        }
    }

    private func invoke(arguments: [String]) async throws -> ContributionsCLIResult {
        guard let executable = locator.locate() else {
            throw ContributionsCLIError.cliNotFound
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let stdout = ContributionsPipeCollector()
        let stderr = ContributionsPipeCollector()
        stdoutPipe.fileHandleForReading.readabilityHandler = {
            stdout.append($0.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = {
            stderr.append($0.availableData)
        }

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<ContributionsCLIResult, any Error>) in
            let timedOut = ContributionsTimeoutFlag()
            process.terminationHandler = { process in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                stdout.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                stderr.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                let command = arguments.joined(separator: " ")
                if timedOut.value {
                    continuation.resume(
                        throwing: ContributionsCLIError.timedOut(command: command)
                    )
                    return
                }
                let status = process.terminationStatus
                if status == 0 {
                    continuation.resume(returning: ContributionsCLIResult(
                        exitStatus: status,
                        stdout: stdout.text
                    ))
                } else {
                    continuation.resume(throwing: ContributionsCLIError.exited(
                        status,
                        message: stderr.lastLine
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
                return
            }
            Task {
                try? await Task.sleep(for: timeout)
                timedOut.set()
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }
}

private final class ContributionsPipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    var lastLine: String {
        text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .last ?? ""
    }
}

private final class ContributionsTimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}
