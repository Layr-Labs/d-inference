import Foundation

/// Schema1 retains legacy retirement evidence. Schema2 additionally binds a
/// raw Apple installation, native qualification and completed disposable cleanup.
public struct SandboxGuestTemplateReceipt: Codable, Equatable, Sendable {
    public static let fileName = ".darkbloom-template.json"
    public let schemaVersion: Int
    public let name: String
    public let installationID: UUID
    public let releaseManifestSHA256: String
    public let guestSHA256: String
    public let bootstrapSHA256: String
    public let launchdSHA256: String
    public let installerSHA256: String
    public let guestOperatingSystemVersion: String
    public let guestArchitecture: String
    public let stoppedVerified: Bool
    public let accountless: SandboxAccountlessTemplateEvidence?
    private let legacyBootstrapRetired: Bool?
    private let hasLegacyBootstrapField: Bool
    private let hasAccountlessField: Bool

    /// Compatibility accessor only; accountless evidence never claims retirement.
    public var bootstrapRetired: Bool { legacyBootstrapRetired == true }
    public var payload: SandboxGuestPayloadIdentity {
        .init(releaseManifestSHA256: releaseManifestSHA256, guestSHA256: guestSHA256,
              bootstrapSHA256: bootstrapSHA256, launchdSHA256: launchdSHA256, installerSHA256: installerSHA256)
    }

    public init(schemaVersion: Int, name: String, installationID: UUID,
                releaseManifestSHA256: String, guestSHA256: String, bootstrapSHA256: String,
                launchdSHA256: String, installerSHA256: String,
                guestOperatingSystemVersion: String, guestArchitecture: String,
                bootstrapRetired: Bool, stoppedVerified: Bool) {
        self.schemaVersion = schemaVersion; self.name = name; self.installationID = installationID
        self.releaseManifestSHA256 = releaseManifestSHA256; self.guestSHA256 = guestSHA256
        self.bootstrapSHA256 = bootstrapSHA256; self.launchdSHA256 = launchdSHA256
        self.installerSHA256 = installerSHA256; self.guestOperatingSystemVersion = guestOperatingSystemVersion
        self.guestArchitecture = guestArchitecture; self.stoppedVerified = stoppedVerified
        legacyBootstrapRetired = bootstrapRetired; hasLegacyBootstrapField = true
        accountless = nil; hasAccountlessField = false
    }

    /// Construction does not bypass validation: incomplete evidence remains
    /// unready and both the publisher and normal clone validator reject it.
    public init(accountless evidence: SandboxAccountlessTemplateEvidence) {
        let installation = evidence.installation
        schemaVersion = 2; name = installation.source.name; installationID = installation.source.installationID
        releaseManifestSHA256 = installation.payload.releaseManifestSHA256
        guestSHA256 = installation.payload.guestSHA256; bootstrapSHA256 = installation.payload.bootstrapSHA256
        launchdSHA256 = installation.payload.launchdSHA256; installerSHA256 = installation.payload.installerSHA256
        guestOperatingSystemVersion = installation.guestOperatingSystemVersion; guestArchitecture = installation.guestArchitecture
        stoppedVerified = evidence.qualification.cleanup.sourceStoppedReverified
        accountless = evidence; hasAccountlessField = true
        legacyBootstrapRetired = nil; hasLegacyBootstrapField = false
    }

    public func hasValidEvidence(for source: SandboxGuestBaseSource) -> Bool {
        guard source.isValid, source.name == name, source.installationID == installationID,
              payload.isValid, stoppedVerified, guestArchitecture == "arm64" else { return false }
        switch schemaVersion {
        case 1:
            return source.kind != .appleRestore && hasLegacyBootstrapField && bootstrapRetired
                && !hasAccountlessField && accountless == nil
        case 2:
            guard !hasLegacyBootstrapField, legacyBootstrapRetired == nil,
                  let accountless, hasAccountlessField else { return false }
            return accountless.ready && accountless.installation.source == source
                && accountless.installation.payload == payload
                && accountless.installation.guestOperatingSystemVersion == guestOperatingSystemVersion
                && accountless.installation.guestArchitecture == guestArchitecture
        default:
            return false
        }
    }

    public func isReady(for source: SandboxGuestBaseSource, guestFiles: [String: String]) -> Bool {
        hasValidEvidence(for: source) && payload.matchesGuestFiles(guestFiles)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, name, installationID, releaseManifestSHA256, guestSHA256, bootstrapSHA256
        case launchdSHA256, installerSHA256, guestOperatingSystemVersion, guestArchitecture
        case bootstrapRetired, stoppedVerified, accountless
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try value.decode(Int.self, forKey: .schemaVersion)
        name = try value.decode(String.self, forKey: .name)
        installationID = try value.decode(UUID.self, forKey: .installationID)
        releaseManifestSHA256 = try value.decode(String.self, forKey: .releaseManifestSHA256)
        guestSHA256 = try value.decode(String.self, forKey: .guestSHA256)
        bootstrapSHA256 = try value.decode(String.self, forKey: .bootstrapSHA256)
        launchdSHA256 = try value.decode(String.self, forKey: .launchdSHA256)
        installerSHA256 = try value.decode(String.self, forKey: .installerSHA256)
        guestOperatingSystemVersion = try value.decode(String.self, forKey: .guestOperatingSystemVersion)
        guestArchitecture = try value.decode(String.self, forKey: .guestArchitecture)
        stoppedVerified = try value.decode(Bool.self, forKey: .stoppedVerified)
        hasLegacyBootstrapField = value.contains(.bootstrapRetired)
        legacyBootstrapRetired = try value.decodeIfPresent(Bool.self, forKey: .bootstrapRetired)
        hasAccountlessField = value.contains(.accountless)
        accountless = try value.decodeIfPresent(SandboxAccountlessTemplateEvidence.self, forKey: .accountless)
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(schemaVersion, forKey: .schemaVersion); try value.encode(name, forKey: .name)
        try value.encode(installationID, forKey: .installationID)
        try value.encode(releaseManifestSHA256, forKey: .releaseManifestSHA256)
        try value.encode(guestSHA256, forKey: .guestSHA256); try value.encode(bootstrapSHA256, forKey: .bootstrapSHA256)
        try value.encode(launchdSHA256, forKey: .launchdSHA256); try value.encode(installerSHA256, forKey: .installerSHA256)
        try value.encode(guestOperatingSystemVersion, forKey: .guestOperatingSystemVersion)
        try value.encode(guestArchitecture, forKey: .guestArchitecture); try value.encode(stoppedVerified, forKey: .stoppedVerified)
        // Preserve explicitly present nulls so malformed evidence cannot become
        // valid merely by decoding and re-encoding it.
        if hasLegacyBootstrapField { try value.encode(legacyBootstrapRetired, forKey: .bootstrapRetired) }
        if hasAccountlessField { try value.encode(accountless, forKey: .accountless) }
    }
}
