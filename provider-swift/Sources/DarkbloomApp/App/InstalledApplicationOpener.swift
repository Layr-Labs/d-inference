import AppKit

/// Injectable boundary around `NSWorkspace` so recovery tests exercise the
/// exact launch configuration used by the shipping app.
@MainActor
protocol InstalledApplicationOpening {
    func openApplication(
        at applicationURL: URL,
        configuration: NSWorkspace.OpenConfiguration
    )
}

@MainActor
struct WorkspaceInstalledApplicationOpener: InstalledApplicationOpening {
    func openApplication(
        at applicationURL: URL,
        configuration: NSWorkspace.OpenConfiguration
    ) {
        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: configuration
        ) { _, error in
            if let error {
                NSLog(
                    "Could not open the managed Darkbloom app at %@: %@",
                    applicationURL.path,
                    error.localizedDescription
                )
            }
        }
    }
}
