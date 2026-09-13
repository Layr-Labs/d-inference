import Foundation

/// Broker-published evidence that a particular base installation contains the
/// signed guest release and was observed stopped after bootstrap retirement.
public struct SandboxGuestTemplateReceipt: Codable, Equatable, Sendable {
    public static let fileName = ".darkbloom-template.json"
    public let schemaVersion: Int
    public let name: String
    public let installationID: UUID
    /// Original installation provenance; reuse requires the four guest hashes
    /// to match a currently verified release, independently of host-only changes.
    public let releaseManifestSHA256: String
    public let guestSHA256: String
    public let bootstrapSHA256: String
    public let launchdSHA256: String
    public let installerSHA256: String
    public let guestOperatingSystemVersion: String
    public let guestArchitecture: String
    public let bootstrapRetired: Bool
    public let stoppedVerified: Bool

    public init(schemaVersion: Int, name: String, installationID: UUID,
                releaseManifestSHA256: String, guestSHA256: String, bootstrapSHA256: String,
                launchdSHA256: String, installerSHA256: String,
                guestOperatingSystemVersion: String, guestArchitecture: String,
                bootstrapRetired: Bool, stoppedVerified: Bool) {
        self.schemaVersion = schemaVersion; self.name = name; self.installationID = installationID
        self.releaseManifestSHA256 = releaseManifestSHA256; self.guestSHA256 = guestSHA256
        self.bootstrapSHA256 = bootstrapSHA256; self.launchdSHA256 = launchdSHA256
        self.installerSHA256 = installerSHA256
        self.guestOperatingSystemVersion = guestOperatingSystemVersion; self.guestArchitecture = guestArchitecture
        self.bootstrapRetired = bootstrapRetired; self.stoppedVerified = stoppedVerified
    }
}
