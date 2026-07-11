import ArgumentParser
import Foundation
import Testing

@testable import darkbloom

@Suite("Fan command")
struct FanCommandTests {
    @Test("fan is registered with safe defaults")
    func parsesDefaults() throws {
        let command = try Darkbloom.parseAsRoot(["fan"])
        guard let fan = command as? Fan else {
            Issue.record("expected Fan command")
            return
        }
        #expect(fan.speed == 90)
        #expect(fan.temperature == 40)
        #expect(fan.pollInterval == 2)
        #expect(!fan.reset)
    }

    @Test("fan controls are adjustable")
    func parsesOverrides() throws {
        let command = try Darkbloom.parseAsRoot([
            "fan",
            "--speed", "75",
            "--temperature", "55",
            "--poll-interval", "1.5",
            "--state-file", "/tmp/provider-state.json",
        ])
        guard let fan = command as? Fan else {
            Issue.record("expected Fan command")
            return
        }
        #expect(fan.speed == 75)
        #expect(fan.temperature == 55)
        #expect(fan.pollInterval == 1.5)
        #expect(fan.stateFile == "/tmp/provider-state.json")
    }

    @Test("reset is an explicit one-shot mode")
    func parsesReset() throws {
        let command = try Darkbloom.parseAsRoot(["fan", "--reset"])
        #expect((command as? Fan)?.reset == true)
    }

    @Test("sudo resolves the invoking user's provider state")
    func resolvesSudoUserHome() {
        let path = Fan.resolveStateFile(
            explicitPath: nil,
            environment: ["SUDO_USER": "alice"],
            currentHome: URL(fileURLWithPath: "/var/root"),
            homeForUser: { user in
                user == "alice"
                    ? URL(fileURLWithPath: "/Users/alice")
                    : nil
            }
        )
        #expect(
            path.path
                == "/Users/alice/.darkbloom/daemon-state.json"
        )
    }

    @Test("explicit paths and state-file environment override defaults")
    func stateFileOverrides() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let explicit = Fan.resolveStateFile(
            explicitPath: "~/custom-state.json",
            environment: ["SUDO_USER": "alice"],
            currentHome: URL(fileURLWithPath: "/var/root"),
            homeForUser: { _ in home }
        )
        #expect(explicit.path == "/Users/alice/custom-state.json")

        let environment = Fan.resolveStateFile(
            explicitPath: nil,
            environment: [
                "SUDO_USER": "alice",
                "DARKBLOOM_STATE_FILE": "/tmp/state.json",
            ],
            currentHome: URL(fileURLWithPath: "/var/root"),
            homeForUser: { _ in home }
        )
        #expect(environment.path == "/tmp/state.json")
    }
}
