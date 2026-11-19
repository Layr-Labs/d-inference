// Test-only: runs the serve loop's startup collector (`collectSecurityPosture`) with the boot-settings command results
// a scenario names (`enabled`, `disabled`, `unread`) and a default kernel SIP value, then the loop's own gate
// (`ProviderLoop.bootSecurityHold`) and, when that lets the loop register, its registration report
// (`ProviderLoop.registrationPrivacyCapabilities`). Prints them as JSON with the commands it answered, for
// `BootSettingsCollectorFixtureTests`. Its own process takes the collector's side effects. Release builds name their
// products, so none builds or ships it.
import Foundation
import ProviderCore

let scenario = CommandLine.arguments.dropFirst().first ?? ""
let rootAnswer: SecurityCommandResult?
let seal: String
switch scenario {
case "enabled":
    rootAnswer = SecurityCommandResult(terminationStatus: 0, stdout: "Authenticated Root status: enabled\n"); seal = "Yes"
case "disabled":
    rootAnswer = SecurityCommandResult(terminationStatus: 0, stdout: "Authenticated Root status: disabled\n"); seal = "Yes"
case "unread":
    rootAnswer = nil; seal = "Broken"
default:
    FileHandle.standardError.write(Data("usage: boot-settings-collector-fixture enabled|disabled|unread\n".utf8))
    exit(64)
}

final class Answered: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [[String]] = []
    func record(_ command: [String]) { lock.withLock { commands.append(command) } }
    var all: [[String]] { lock.withLock { commands } }
}
let answered = Answered()
let commands = SecurityCommandRunner { path, arguments in
    answered.record([path] + arguments)
    switch (path, arguments) {
    case ("/usr/bin/csrutil", ["status"]):
        return SecurityCommandResult(terminationStatus: 0, stdout: "System Integrity Protection status: enabled.\n")
    case ("/usr/bin/csrutil", ["authenticated-root", "status"]):
        guard let rootAnswer else { throw SecurityCommandRunner.CommandError.timedOut }
        return rootAnswer
    case ("/usr/sbin/diskutil", ["info", "/"]):
        return SecurityCommandResult(terminationStatus: 0, stdout: "   Sealed:                    \(seal)\n")
    case ("/usr/sbin/system_profiler", ["-json", "SPiBridgeDataType"]):
        return SecurityCommandResult(terminationStatus: 0, stdout: #"{"SPiBridgeDataType":[{"ibridge_secure_boot":"Full Security"}]}"#)
    default:
        throw SecurityCommandRunner.CommandError.timedOut
    }
}

let posture = collectSecurityPosture(bootSettingsCommands: commands, kernelSIP: { SIPConfiguration(rawValue: 0) })
let hold = ProviderLoop.bootSecurityHold(posture).map(\.kind.rawValue)
var registration: Any = NSNull()
if hold.isEmpty {
    let report = try JSONEncoder().encode(ProviderLoop.registrationPrivacyCapabilities(posture))
    registration = try JSONSerialization.jsonObject(with: report)
}
let output: [String: Any] = ["hold": hold, "registration": registration, "commands": answered.all]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]))
