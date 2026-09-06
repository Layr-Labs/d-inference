import Foundation
import ProviderCoreFoundation

/// Uses the same injected /usr/bin/open convention as EnrollmentSettingsService.
/// Opening the pane does not change any network settings.
enum DiagnosticNetworkSettings {
    static let deepLink = "x-apple.systempreferences:com.apple.preference.network"

    static func open(
        using command: SystemSettingsProfileRemovalPane.OpenCommand = { arguments in
            try SystemAppInstallCommandExecutor().run(
                URL(fileURLWithPath: "/usr/bin/open"),
                arguments: arguments
            )
        }
    ) throws {
        try command([deepLink])
    }
}
