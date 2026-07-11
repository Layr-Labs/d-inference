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
        #expect(!fan.installHelper)
    }

    @Test("fan controls are adjustable")
    func parsesOverrides() throws {
        let command = try Darkbloom.parseAsRoot([
            "fan",
            "--speed", "95",
            "--temperature", "55",
            "--poll-interval", "1.5",
            "--activity-file", "/tmp/provider-state.json",
        ])
        guard let fan = command as? Fan else {
            Issue.record("expected Fan command")
            return
        }
        #expect(fan.speed == 95)
        #expect(fan.temperature == 55)
        #expect(fan.pollInterval == 1.5)
        #expect(fan.activityFile == "/tmp/provider-state.json")
    }

    @Test("reset is an explicit one-shot mode")
    func parsesReset() throws {
        let command = try Darkbloom.parseAsRoot(["fan", "--reset"])
        #expect((command as? Fan)?.reset == true)
    }

    @Test("helper installation is an explicit one-shot mode")
    func parsesHelperInstall() throws {
        let command = try Darkbloom.parseAsRoot([
            "fan",
            "--install-helper",
        ])
        #expect((command as? Fan)?.installHelper == true)
    }

    @Test("default state belongs to the unprivileged user")
    func resolvesUserHome() {
        let path = Fan.resolveActivityFile(
            explicitPath: nil,
            environment: [:],
            currentHome: URL(fileURLWithPath: "/Users/alice")
        )
        #expect(
            path.path
                == "/Users/alice/.darkbloom/inference-activity.json"
        )
    }

    @Test("explicit paths and state-file environment override defaults")
    func stateFileOverrides() {
        let home = URL(fileURLWithPath: "/Users/alice")
        let explicit = Fan.resolveActivityFile(
            explicitPath: "~/custom-state.json",
            environment: [:],
            currentHome: home
        )
        #expect(explicit.path == "/Users/alice/custom-state.json")

        let environment = Fan.resolveActivityFile(
            explicitPath: nil,
            environment: [
                "DARKBLOOM_INFERENCE_ACTIVITY_FILE": "/tmp/state.json",
            ],
            currentHome: home
        )
        #expect(environment.path == "/tmp/state.json")
    }

    @Test("helper installer resolves only an embedded package")
    func helperPackageResolution() throws {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("Darkbloom-\(UUID().uuidString).app")
        let resources = app
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")
        try FileManager.default.createDirectory(
            at: resources,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: app) }
        let package = resources.appendingPathComponent(
            "DarkbloomFanHelper.pkg"
        )
        try Data().write(to: package)

        #expect(
            try FanHelperInstaller.packageURL(
                bundleURL: app,
                executableURL: nil
            ) == package
        )
    }
}
