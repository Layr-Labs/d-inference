import Foundation
import SandboxRuntime

/// Stage only under the staging journal. Mount and cleanup authority is shared
/// with post-boot collection, while the payload operation stays phase-specific.
struct AccountlessOfflineStager {
    let journal: AccountlessInstallationStagingJournal
    let tools: AccountlessMountSystemTools
    let image: URL
    let imageDescriptor: Int32
    let validateOwnership: () throws -> Void

    func stage(payloadDirectory: URL) async throws {
        try validateOwnership()
        let transaction = try AccountlessOfflineImageTransaction(attempts: journal.mountAttempts(),
            maintenanceSHA256: journal.maintenanceIntent().journalSHA256, tools: tools,
            image: image, imageDescriptor: imageDescriptor, validateOwnership: validateOwnership)
        try await transaction.perform { data, _ in
            try AccountlessOfflineOverlay().stage(dataDirectory: data, payloadDirectory: payloadDirectory, journal: journal)
        }
    }
}
