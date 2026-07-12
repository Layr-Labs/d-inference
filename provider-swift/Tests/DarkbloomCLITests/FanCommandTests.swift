import ArgumentParser
import Testing

@testable import darkbloom

@Suite("Fan command")
struct FanCommandTests {
    @Test("fan is registered and defaults to status")
    func fanParses() throws {
        let command = try Darkbloom.parseAsRoot(["fan"])
        #expect(command is Fan.Status)
    }

    @Test("enable parses the agreed policy knobs")
    func enableParses() throws {
        let command = try Darkbloom.parseAsRoot([
            "fan", "enable", "--speed", "60", "--temperature", "50",
        ])
        guard let enable = command as? Fan.Enable else {
            Issue.record("expected Fan.Enable")
            return
        }
        #expect(enable.speed == 60)
        #expect(enable.temperature == 50)
    }

    @Test("configure accepts either setting independently")
    func configureParses() throws {
        let command = try Darkbloom.parseAsRoot([
            "fan", "configure", "--speed", "90",
        ])
        guard let configure = command as? Fan.Configure else {
            Issue.record("expected Fan.Configure")
            return
        }
        #expect(configure.speed == 90)
        #expect(configure.temperature == nil)
    }

    @Test("executable path decoding preserves non-ASCII UTF-8 bytes")
    func executablePathDecodesNonASCII() {
        let expected = "/Users/José/Darkbloom.app/Contents/MacOS/darkbloom"
        let buffer = expected.utf8.map { CChar(bitPattern: $0) } + [0, 65]

        #expect(FanServiceManager.decodeExecutablePath(buffer) == expected)
    }
}
