import Darwin
import Foundation

/// Records every expectation instead of stopping at the first failure.
/// Arguments: the terminal child executable, the coordinator registration
/// vector, and a scratch directory under the checkout.
@main enum PairingCheck {
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failures = [String]()
    static let lock = NSLock()
    nonisolated(unsafe) static var arguments = [String]()

    static func expect(_ condition: Bool, _ message: String, line: Int = #line) {
        lock.withLock { if condition { passed += 1 } else { failures.append("line \(line): \(message)") } }
    }

    static func expectEqual<Value: Equatable>(_ actual: Value, _ expected: Value, _ message: String, line: Int = #line) {
        expect(actual == expected, "\(message): got \(actual), expected \(expected)", line: line)
    }

    static var child: String { arguments[1] }
    static var vector: String { arguments[2] }
    static var scratch: URL { URL(fileURLWithPath: arguments[3]) }

    static func freshDirectory(_ name: String) -> URL {
        let url = scratch.appendingPathComponent(name + "-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    static func main() {
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(240); defer { alarm(0) }
        arguments = CommandLine.arguments
        guard arguments.count == 4 else { print("usage: PairingCheck <terminal child> <vector json> <scratch dir>"); exit(2) }
        let groups: [(String, () -> Void)] = [
            ("coordinator vector: pins and roster bytes", coordinatorVector),
            ("message shapes", messageShapes),
            ("ceremony: both confirm", ceremonyBothConfirm),
            ("ceremony: re-pairing raises the generation", ceremonyGeneration),
            ("ceremony: a relay sees different codes", ceremonyRelay),
            ("ceremony: tampering and refusals", ceremonyTampering),
            ("ceremony: declines and rollback", ceremonyDeclines),
            ("store: owner-only files", storeFiles),
            ("store: rollback and unpair", storeRollback),
            ("gate: attempts, lockout, persistence", gateLockout),
            ("offer rate limit", offerRateLimit),
            ("link channel: pairing over loopback", linkPairing),
            ("link channel: decline, lockout, expiry", linkRefusals),
            ("discovery: datagrams, targets, who dials, who yields", discoveryShapes),
            ("discovery: a listener answers on loopback, rate limit", discoveryLoopback),
            ("discovery: both press l, no address typed", discoveryCeremony),
            ("pseudo-terminal: both confirm", terminalBothConfirm),
            ("pseudo-terminal: one declines", terminalDecline),
        ]
        for (name, group) in groups {
            let before = (passed, failures.count)
            group()
            print("\(failures.count == before.1 ? "ok  " : "FAIL") \(name) (\(passed - before.0) checks)")
        }
        print("\(passed) checks passed, \(failures.count) failed")
        for failure in failures { print("  " + failure) }
        exit(failures.isEmpty ? 0 : 1)
    }
}
