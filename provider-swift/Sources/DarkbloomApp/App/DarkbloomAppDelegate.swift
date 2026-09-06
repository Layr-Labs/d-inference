import AppKit

@MainActor
final class DarkbloomAppDelegate: NSObject, NSApplicationDelegate {
    private(set) var installState: AppInstallLaunchState
    var prepareForTermination: (@MainActor () async -> Bool)?
    private var terminationIsPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationIsPending else { return .terminateLater }
        guard let prepareForTermination else { return .terminateNow }
        terminationIsPending = true
        Task { @MainActor in
            let canTerminate = await prepareForTermination()
            terminationIsPending = false
            sender.reply(toApplicationShouldTerminate: canTerminate)
            if !canTerminate {
                sender.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "The local session is still stopping"
                alert.informativeText = "Darkbloom stayed open because its local process has not exited. Check Local API and try quitting again."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
        return .terminateLater
    }

    override init() {
        let coordinator = AppInstallCoordinator()
        installState = Self.resolveInstallState(
            destinationURL: coordinator.destinationURL,
            coordinate: coordinator.coordinate
        )
        super.init()
    }

    init(
        destinationURL: URL,
        coordinate: () throws -> AppInstallOutcome
    ) {
        installState = Self.resolveInstallState(
            destinationURL: destinationURL,
            coordinate: coordinate
        )
        super.init()
    }

    func applicationWillFinishLaunching(_: Notification) {
        guard case .handingOff = installState else {
            return
        }
        NSApp.terminate(nil)
    }

    private static func resolveInstallState(
        destinationURL: URL,
        coordinate: () throws -> AppInstallOutcome
    ) -> AppInstallLaunchState {
        do {
            switch try coordinate() {
            case .continueLaunch:
                return .ready
            case .relocated:
                return .handingOff
            case .relaunchRequired(let destination, let preservedForeignApp):
                return .relaunchRequired(
                    AppInstallationRecovery(
                        destination: destination,
                        preservedForeignApp: preservedForeignApp
                    )
                )
            }
        } catch {
            return .failed(AppInstallationFailure(
                error: error,
                destination: destinationURL
            ))
        }
    }

    func applicationDidFinishLaunching(_: Notification) {
        #if DEBUG
        PreviewAppearance.applyIfRequested(to: NSApp)
        #endif
        guard installState.isInteractive else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
