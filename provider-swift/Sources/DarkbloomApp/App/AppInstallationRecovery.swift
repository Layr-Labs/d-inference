import AppKit
import ProviderCoreFoundation

struct AppInstallationRecovery: Equatable, Sendable {
    let destination: URL
    let preservedForeignApp: URL?

    var managedCLIURL: URL {
        ManagedProviderCLIPathValidator().validatedCLIURL(appBundleURL: destination)
            ?? ManagedProviderInstallLayout.cliURL(appBundleURL: destination)
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
