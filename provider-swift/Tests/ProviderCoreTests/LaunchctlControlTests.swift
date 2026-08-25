import Foundation
import Testing
@testable import ProviderCore

@Suite("Launchctl executable path persistence")
struct LaunchctlControlTests {
    private let home = URL(fileURLWithPath: "/Users/provider")
    private let expected =
        "/Users/provider/.darkbloom/Darkbloom.app/Contents/MacOS/darkbloom"

    @Test(
        "LaunchAgent and watchdog never persist the source process path",
        arguments: [
            "/Users/provider/Downloads/Darkbloom.app/Contents/MacOS/darkbloom",
            "/private/var/folders/zz/AppTranslocation/ABC/d/Darkbloom.app/Contents/MacOS/darkbloom",
        ]
    )
    func launchdArgumentsUseManagedCLI(sourceProcessPath: String) {
        let persistedPath = LaunchctlControl.managedExecutablePath(
            homeDirectory: home
        )

        let providerArguments = LaunchAgent.serviceProgramArguments(
            binaryPath: persistedPath,
            coordinatorURL: "wss://api.darkbloom.dev/ws/provider",
            models: [],
            idleTimeout: nil,
            configPath: nil
        )
        let watchdogPlist = WatchdogAgent.makeWatchdogPlist(
            label: "io.darkbloom.watchdog",
            programArguments: [persistedPath, "watchdog"],
            logPath: "/tmp/watchdog.log"
        )
        let watchdogArguments =
            watchdogPlist["ProgramArguments"] as? [String]

        #expect(persistedPath == expected)
        #expect(providerArguments.first == expected)
        #expect(watchdogArguments?.first == expected)
        #expect(providerArguments.first != sourceProcessPath)
        #expect(watchdogArguments?.first != sourceProcessPath)
    }
}
