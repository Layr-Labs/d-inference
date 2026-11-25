import Foundation
import Testing

/// The serve loop's startup collector (`collectSecurityPosture`), run by the `boot-settings-collector-fixture` helper
/// with command results a scenario names: the collector reads them through the same functions a release start uses,
/// then the loop's own gate (`ProviderLoop.bootSecurityHold`) and registration report
/// (`ProviderLoop.registrationPrivacyCapabilities`) decide. The helper's own process takes the collector's side effects.
@Suite("the startup collector, its gate and its registration report, from command results")
struct BootSettingsCollectorFixtureTests {
    private static func fixture() -> String {
        let bundle = Bundle(for: BootSettingsCollectorFixtureAnchor.self).bundleURL
        let products = bundle.pathExtension == "xctest" ? bundle.deletingLastPathComponent() : bundle
        return products.appendingPathComponent("boot-settings-collector-fixture").path
    }

    private static func run(_ scenario: String) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: fixture())
        process.arguments = [scenario]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        // Read on its own queue, so a descendant that holds stdout open can't block the test past its deadline.
        let read = DispatchSemaphore(value: 0)
        let collected = Collected()
        DispatchQueue(label: "boot-settings-collector-fixture.stdout").async {
            collected.set(output.fileHandleForReading.readDataToEndOfFile())
            read.signal()
        }
        // A parent-side deadline: a reading that hangs fails the test instead of wedging the shard.
        guard exited.wait(timeout: .now() + 60) == .success, read.wait(timeout: .now() + 5) == .success else {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? output.fileHandleForReading.close()
            throw FixtureTimedOut(scenario: scenario)
        }
        #expect(process.terminationReason == .exit && process.terminationStatus == 0, "\(scenario): exited normally")
        return try #require(try JSONSerialization.jsonObject(with: collected.data) as? [String: Any])
    }

    private static func askedForAuthenticatedRoot(_ result: [String: Any]) -> Bool {
        (result["commands"] as? [[String]] ?? []).contains(["/usr/bin/csrutil", "authenticated-root", "status"])
    }

    @Test("csrutil says enabled: no hold, and the registration reports it with the exact SIP value and Full Security")
    func enabled() throws {
        let result = try Self.run("enabled")
        #expect(result["hold"] as? [String] == [])
        let registration = try #require(result["registration"] as? [String: Any])
        #expect(registration["authenticated_root"] as? Bool == true)
        #expect(registration["sip_configuration"] as? Int == 0)
        #expect(registration["secure_boot"] as? String == "full")
        #expect(Self.askedForAuthenticatedRoot(result))
    }

    @Test("csrutil says disabled: the loop holds for authenticated root and doesn't register")
    func disabled() throws {
        let result = try Self.run("disabled")
        #expect(result["hold"] as? [String] == ["authenticated_root"])
        #expect(result["registration"] is NSNull)
        #expect(Self.askedForAuthenticatedRoot(result))
    }

    @Test("csrutil doesn't answer and the seal reads Broken: no hold, and the registration leaves the field out")
    func unread() throws {
        let result = try Self.run("unread")
        #expect(result["hold"] as? [String] == [])
        let registration = try #require(result["registration"] as? [String: Any])
        #expect(registration.keys.contains("authenticated_root") == false)
        #expect(registration["secure_boot"] as? String == "full")
        let rootCommands = (result["commands"] as? [[String]] ?? []).filter {
            $0 == ["/usr/bin/csrutil", "authenticated-root", "status"] || $0 == ["/usr/sbin/diskutil", "info", "/"]
        }
        #expect(rootCommands == [["/usr/bin/csrutil", "authenticated-root", "status"], ["/usr/sbin/diskutil", "info", "/"]],
                "csrutil first, then the seal")
    }

    private static func secureBootReads(_ result: [String: Any]) -> Int {
        (result["commands"] as? [[String]] ?? []).filter { $0 == ["/usr/sbin/system_profiler", "-json", "SPiBridgeDataType"] }.count
    }

    @Test("system_profiler fails twice, then reads Full Security: the collector reads again, and the registration reports full")
    func secureBootReadAgain() throws {
        let result = try Self.run("secure-boot-retry")
        #expect(result["hold"] as? [String] == [])
        let registration = try #require(result["registration"] as? [String: Any])
        #expect(registration["secure_boot"] as? String == "full")
        #expect(registration.keys.contains("secure_boot_read_failure") == false)
        #expect(registration.keys.contains("secure_boot_read_attempts") == false)
        #expect(Self.secureBootReads(result) == 3)
    }

    @Test("system_profiler always fails: the registration reports unknown, why, and after how many reads")
    func secureBootUnread() throws {
        let result = try Self.run("secure-boot-unread")
        #expect(result["hold"] as? [String] == [])
        let registration = try #require(result["registration"] as? [String: Any])
        #expect(registration["secure_boot"] as? String == "unknown")
        #expect(registration["secure_boot_read_failure"] as? String == "exit_status")
        let reads = Self.secureBootReads(result)
        #expect(reads >= 2, "never unknown from one read")
        #expect(registration["secure_boot_read_attempts"] as? Int == reads)
    }

    @Test("system_profiler fails, then reads Permissive Security: the loop holds for Secure Boot and doesn't register")
    func secureBootDowngradeOnASecondRead() throws {
        let result = try Self.run("secure-boot-downgrade")
        #expect(result["hold"] as? [String] == ["secure_boot"])
        #expect(result["registration"] is NSNull)
        #expect(Self.secureBootReads(result) == 2)
    }
}

private final class BootSettingsCollectorFixtureAnchor {}

private struct FixtureTimedOut: Error, CustomStringConvertible {
    let scenario: String
    var description: String { "\(scenario): the fixture did not finish in time" }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func set(_ data: Data) { lock.withLock { bytes = data } }
    var data: Data { lock.withLock { bytes } }
}
