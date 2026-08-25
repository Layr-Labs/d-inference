import AppKit

struct AppInstallationRecovery: Equatable, Sendable {
    let destination: URL
    let preservedForeignApp: URL?

    var managedCLIURL: URL {
        destination.appendingPathComponent("Contents/MacOS/darkbloom")
    }

    @MainActor
    func openInstalledApp() {
        openInstalledApp(using: WorkspaceInstalledApplicationOpener())
    }

    @MainActor
    func openInstalledApp(using opener: any InstalledApplicationOpening) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        opener.openApplication(
            at: destination,
            configuration: configuration
        )
    }
}
