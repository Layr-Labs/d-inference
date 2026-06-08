#if os(macOS)
import AppKit
import ArgumentParser
import Foundation
import ProviderCore

/// Hosts the long-running provider serve modes under an NSApplication(.accessory)
/// run loop so the process can registerForRemoteNotifications() and receive APNs
/// code-identity challenges (v0.6.0). Proven pattern: apns-r2-probe/coexist.swift.
enum ProviderAppKitHost {
    /// The serve modes that run long and need APNs: `start --foreground` (the
    /// launchd-spawned daemon) and `start --local` (standalone). A bare `start`
    /// installs the launchd agent and exits — it must NOT host AppKit.
    static func shouldHost(_ args: [String]) -> Bool {
        guard args.first == "start" else { return false }
        return args.contains("--foreground") || args.contains("--local")
    }

    /// Takes over the main thread with the AppKit event loop (does not return).
    @MainActor
    static func runHosted(_ args: [String]) -> Never {
        let app = NSApplication.shared
        let delegate = ProviderAppDelegate(args: args)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        exit(0) // app.run() does not return; defensive.
    }
}

/// AppKit delegate for the hosted serve process. Owns the APNs callbacks (on the
/// main thread) and bridges them to the ProviderLoop via APNsBridge. Launches the
/// actual serve command in a child Task so app.run() keeps the main thread.
@MainActor
final class ProviderAppDelegate: NSObject, NSApplicationDelegate {
    private let args: [String]

    init(args: [String]) {
        self.args = args
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
        let args = self.args
        Task {
            do {
                let command = try Darkbloom.parseAsRoot(args)
                if let asyncCommand = command as? AsyncParsableCommand {
                    var cmd = asyncCommand
                    try await cmd.run()
                } else {
                    var cmd = command
                    try cmd.run()
                }
                exit(0)
            } catch {
                Darkbloom.exit(withError: error)
            }
        }
    }

    func application(_: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        APNsBridge.shared.setDeviceToken(hex)
    }

    func application(_: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        printError("APNs registration failed: \(error.localizedDescription) — provider running un-attested")
    }

    func application(_: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        APNsBridge.shared.deliverPush(userInfo)
    }
}
#endif
