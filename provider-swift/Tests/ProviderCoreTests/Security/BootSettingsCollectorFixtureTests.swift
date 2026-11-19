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
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationReason == .exit && process.terminationStatus == 0, "\(scenario): exited normally")
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
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
        #expect((result["commands"] as? [[String]] ?? []).contains(["/usr/sbin/diskutil", "info", "/"]))
    }
}

private final class BootSettingsCollectorFixtureAnchor {}
