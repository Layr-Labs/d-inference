import Foundation
import ProviderCoreFoundation

protocol EnrollmentSettingsOpening: Sendable {
    func openProfilesPaneForRemoval()
}

struct EnrollmentSettingsService: EnrollmentSettingsOpening {
    typealias OpenCommand = SystemSettingsProfileRemovalPane.OpenCommand

    private let openCommand: OpenCommand

    init(
        openCommand: @escaping OpenCommand = { arguments in
            try SystemAppInstallCommandExecutor().run(
                URL(fileURLWithPath: "/usr/bin/open"),
                arguments: arguments
            )
        }
    ) {
        self.openCommand = openCommand
    }

    func openProfilesPaneForRemoval() {
        SystemSettingsProfileRemovalPane.open(using: openCommand)
    }
}
