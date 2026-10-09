import Foundation
import Darwin
@testable import InstalledContract

/// Records every expectation instead of stopping at the first failure, so one
/// run shows the whole state of the console.
@main enum ClusterConsoleCheck {
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failures = [String]()
    /// The stand-in executables and files the runner built, in argument order.
    nonisolated(unsafe) static var probe = URL(fileURLWithPath: "/")
    nonisolated(unsafe) static var owner = URL(fileURLWithPath: "/")
    nonisolated(unsafe) static var worker = URL(fileURLWithPath: "/")
    nonisolated(unsafe) static var sessionStandIn = URL(fileURLWithPath: "/")
    nonisolated(unsafe) static var wiringTable = URL(fileURLWithPath: "/")
    nonisolated(unsafe) static var adapterSource = URL(fileURLWithPath: "/")
    /// Fixture files live under the working directory, which the runner removes.
    nonisolated(unsafe) static var scratch = URL(fileURLWithPath: "/")

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
        if condition { passed += 1 } else { failures.append("line \(line): \(message())") }
    }

    static func expectEqual<Value: Equatable>(_ actual: Value, _ expected: Value, _ message: String, line: Int = #line) {
        expect(actual == expected, "\(message): got \(actual), expected \(expected)", line: line)
    }

    static func main() {
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(120); defer { alarm(0) }
        let arguments = CommandLine.arguments
        guard arguments.count == 7 else {
            print("usage: ClusterConsoleCheck probe owner worker session-stand-in wiring-table adapter-source")
            exit(64)
        }
        probe = URL(fileURLWithPath: arguments[1]); owner = URL(fileURLWithPath: arguments[2])
        worker = URL(fileURLWithPath: arguments[3]); sessionStandIn = URL(fileURLWithPath: arguments[4])
        wiringTable = URL(fileURLWithPath: arguments[5]); adapterSource = URL(fileURLWithPath: arguments[6])
        scratch = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("console-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }

        let groups: [(String, () throws -> Void)] = [
            ("wiring table", wiringTableMatchesCode),
            ("key decoder", keyDecoder),
            ("reducer: refresh and polling", reducerRefresh),
            ("reducer: link onboarding", reducerOnboarding),
            ("reducer: actions and re-entrancy", reducerActions),
            ("reducer: trust is never automatic", reducerTrust),
            ("reducer: session", reducerSession),
            ("reducer: leaving", reducerLeaving),
            ("renderer: sizes", rendererSizes),
            ("renderer: content", rendererContent),
            ("redaction", redaction),
            ("diagnostic export", diagnosticExport),
            ("saved setup, trust and candidate", savedSetup),
            ("link fix dry run and alias record", linkFixPreview),
            ("recovery results", recoveryResults),
            ("terminal mode", terminalMode),
            ("run loop on a pseudo-terminal", runLoopOnPseudoTerminal),
            ("resize", resize),
            ("cancellation", cancellation),
            ("re-entrancy on a pseudo-terminal", reentrancy),
            ("second instance", secondInstance),
            ("session process", sessionProcess),
            ("session through the installed fixtures", sessionThroughInstalledFixtures),
        ]
        // Set to follow a run that stops: each group is named on standard error as it starts.
        let narrate = ProcessInfo.processInfo.environment["CLUSTER_CONSOLE_CHECK_VERBOSE"] != nil
        for (name, group) in groups {
            if narrate { FileHandle.standardError.write(Data("\(name)\n".utf8)) }
            do { try group() } catch { failures.append("\(name): threw \(error)") }
        }
        guard failures.isEmpty else {
            for failure in failures { print("FAILED \(failure)") }
            print("Cluster console: \(failures.count) of \(passed + failures.count) expectations failed in \(groups.count) groups")
            exit(1)
        }
        print("Cluster console: \(passed) expectations in \(groups.count) groups passed; terminals were pseudo-terminals, operations were scripted, and the only processes started were /bin/sh and the fixture stand-ins")
    }
}
