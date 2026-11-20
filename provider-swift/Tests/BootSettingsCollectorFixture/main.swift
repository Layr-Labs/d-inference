// Test-only: runs the serve loop's startup collector (`collectSecurityPosture`) with the boot-settings command results
// a scenario names and a default kernel SIP value, then the loop's own gate (`ProviderLoop.bootSecurityHold`) and,
// when that lets the loop register, its registration report (`ProviderLoop.registrationPrivacyCapabilities`). Prints
// them as JSON with the commands it answered, for `BootSettingsCollectorFixtureTests`. Authenticated root: `enabled`,
// `disabled`, `unread`. Secure Boot, with authenticated root enabled: `secure-boot-retry` (system_profiler fails twice,
// then reads Full Security), `secure-boot-unread` (it always fails), `secure-boot-downgrade` (it fails once, then reads
// Permissive Security). Secure Boot is read again on a short schedule. Its own process takes the collector's side
// effects. Release builds name their products, so none builds or ships it.
import Foundation
import ProviderCore

let scenario = CommandLine.arguments.dropFirst().first ?? ""
let enabledRoot = SecurityCommandResult(terminationStatus: 0, stdout: "Authenticated Root status: enabled\n")
let fullSecurity = SecurityCommandResult(terminationStatus: 0,
                                         stdout: #"{"SPiBridgeDataType":[{"ibridge_secure_boot":"Full Security"}]}"#)
let failedReport = SecurityCommandResult(terminationStatus: 1, stderr: "system_profiler: no report\n")
let rootAnswer: SecurityCommandResult?
let seal: String
/// system_profiler's answers in order; the last one repeats.
let secureBootAnswers: [SecurityCommandResult]
switch scenario {
case "enabled":
    rootAnswer = enabledRoot; seal = "Yes"; secureBootAnswers = [fullSecurity]
case "disabled":
    rootAnswer = SecurityCommandResult(terminationStatus: 0, stdout: "Authenticated Root status: disabled\n"); seal = "Yes"
    secureBootAnswers = [fullSecurity]
case "unread":
    rootAnswer = nil; seal = "Broken"; secureBootAnswers = [fullSecurity]
case "secure-boot-retry":
    rootAnswer = enabledRoot; seal = "Yes"; secureBootAnswers = [failedReport, failedReport, fullSecurity]
case "secure-boot-unread":
    rootAnswer = enabledRoot; seal = "Yes"; secureBootAnswers = [failedReport]
case "secure-boot-downgrade":
    rootAnswer = enabledRoot; seal = "Yes"
    secureBootAnswers = [failedReport, SecurityCommandResult(
        terminationStatus: 0, stdout: #"{"SPiBridgeDataType":[{"ibridge_secure_boot":"Permissive Security"}]}"#)]
default:
    FileHandle.standardError.write(Data(
        "usage: boot-settings-collector-fixture enabled|disabled|unread|secure-boot-retry|secure-boot-unread|secure-boot-downgrade\n".utf8))
    exit(64)
}

final class Answered: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [[String]] = []
    func record(_ command: [String]) -> Int {
        lock.withLock {
            commands.append(command)
            return commands.filter { $0 == command }.count
        }
    }
    var all: [[String]] { lock.withLock { commands } }
}
let answered = Answered()
let commands = SecurityCommandRunner { path, arguments in
    let count = answered.record([path] + arguments)
    switch (path, arguments) {
    case ("/usr/bin/csrutil", ["status"]):
        return SecurityCommandResult(terminationStatus: 0, stdout: "System Integrity Protection status: enabled.\n")
    case ("/usr/bin/csrutil", ["authenticated-root", "status"]):
        guard let rootAnswer else { throw SecurityCommandRunner.CommandError.timedOut }
        return rootAnswer
    case ("/usr/sbin/diskutil", ["info", "/"]):
        return SecurityCommandResult(terminationStatus: 0, stdout: "   Sealed:                    \(seal)\n")
    case ("/usr/sbin/system_profiler", ["-json", "SPiBridgeDataType"]):
        return secureBootAnswers[min(count, secureBootAnswers.count) - 1]
    default:
        throw SecurityCommandRunner.CommandError.timedOut
    }
}

/// The collector's result, handed from its task to this (synchronous) top-level code.
final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SecurityPosture?
    func set(_ posture: SecurityPosture?) { lock.withLock { value = posture } }
    var posture: SecurityPosture? { lock.withLock { value } }
}

/// Runs the collector on `commands`, reading Secure Boot again on a short schedule, and waits for it.
func collect(_ commands: SecurityCommandRunner) -> SecurityPosture? {
    let collected = Collected()
    let finished = DispatchSemaphore(value: 0)
    Task.detached {
        collected.set(await collectSecurityPosture(
            bootSettingsCommands: commands, kernelSIP: { SIPConfiguration(rawValue: 0) },
            secureBootRetry: SecureBootReadRetry(budget: 1.5, firstWait: 0.05, maxWait: 0.1, readTimeout: 1)))
        finished.signal()
    }
    finished.wait()
    return collected.posture
}

guard let posture = collect(commands) else { exit(70) }
let hold = ProviderLoop.bootSecurityHold(posture).map(\.kind.rawValue)
var registration: Any = NSNull()
if hold.isEmpty {
    let report = try JSONEncoder().encode(ProviderLoop.registrationPrivacyCapabilities(posture))
    registration = try JSONSerialization.jsonObject(with: report)
}
let output: [String: Any] = ["hold": hold, "registration": registration, "commands": answered.all]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]))
