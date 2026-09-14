import Foundation

public enum SandboxGuestBootstrapAccountPolicy: String, Codable, Equatable, Sendable {
    case neverProvisioned
    case retired
}

public enum SandboxGuestInstallationMethod: String, Codable, Equatable, Sendable {
    case firstBootRootJob
}

public enum SandboxGuestInstallationPhase: String, Codable, Equatable, Sendable {
    case rootJobStarted
    case installationComplete
}

public enum SandboxGuestBaseSourceKind: String, Codable, Equatable, Sendable {
    case appleRestore = "apple_restore"
    case legacyRestoreImage = "restore_image"
    case localTemplate = "local_template"
}

/// The exact private ownership record is cheap to bind and includes the source,
/// owner and resource commitments. This digest is not a hash of the VM disk.
public struct SandboxGuestBaseSource: Codable, Equatable, Sendable {
    public let name: String
    public let installationID: UUID
    public let kind: SandboxGuestBaseSourceKind
    public let reference: String
    public let ownershipSHA256: String

    public init(name: String, installationID: UUID, kind: SandboxGuestBaseSourceKind,
                reference: String, ownershipSHA256: String) {
        self.name = name; self.installationID = installationID; self.kind = kind
        self.reference = reference; self.ownershipSHA256 = ownershipSHA256
    }

    public var isValid: Bool {
        SandboxGuestReceiptPolicy.isName(name) && SandboxGuestReceiptPolicy.isDigest(ownershipSHA256)
            && !reference.isEmpty && reference.utf8.count <= 4096 && !reference.contains("\0")
            && (kind == .localTemplate ? SandboxGuestReceiptPolicy.isName(reference) : reference.hasPrefix("/"))
    }
}

public struct SandboxGuestPayloadIdentity: Codable, Equatable, Sendable {
    /// Provenance of the signed manifest used for installation, retained across
    /// host-only upgrades. Current compatibility follows all four guest hashes.
    public let releaseManifestSHA256: String
    public let guestSHA256: String
    public let bootstrapSHA256: String
    public let launchdSHA256: String
    public let installerSHA256: String

    public init(releaseManifestSHA256: String, guestSHA256: String, bootstrapSHA256: String,
                launchdSHA256: String, installerSHA256: String) {
        self.releaseManifestSHA256 = releaseManifestSHA256; self.guestSHA256 = guestSHA256
        self.bootstrapSHA256 = bootstrapSHA256; self.launchdSHA256 = launchdSHA256
        self.installerSHA256 = installerSHA256
    }

    public var isValid: Bool {
        [releaseManifestSHA256, guestSHA256, bootstrapSHA256, launchdSHA256, installerSHA256]
            .allSatisfy(SandboxGuestReceiptPolicy.isDigest)
    }

    public func matchesGuestFiles(_ files: [String: String]) -> Bool {
        isValid && guestSHA256 == files["guest/darkbloom-sandbox-guest"]
            && bootstrapSHA256 == files["guest/darkbloom-sandbox-bootstrap.sh"]
            && launchdSHA256 == files["guest/io.darkbloom.sandbox.guest.plist"]
            && installerSHA256 == files["guest/install-sandbox-guest.sh"]
    }
}

/// Schema2 installation evidence is deliberately not template readiness.
/// A root job can publish its start before any installer or native guest test.
public struct SandboxAccountlessInstallationReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let source: SandboxGuestBaseSource
    public let rootJobID: UUID
    public let method: SandboxGuestInstallationMethod
    public let bootstrapAccountPolicy: SandboxGuestBootstrapAccountPolicy
    public let phase: SandboxGuestInstallationPhase
    public let payload: SandboxGuestPayloadIdentity
    public let guestOperatingSystemVersion: String
    public let guestArchitecture: String
    public let virtualizedRootObserved: Bool
    public let signedInstallerVerified: Bool
    public let installerExitCode: Int32?
    public let installedPayloadVerified: Bool?
    public let bootstrapAccountAbsent: Bool?
    public let tenantIdentityVerified: Bool?

    public init(schemaVersion: Int = 2, source: SandboxGuestBaseSource, rootJobID: UUID,
                method: SandboxGuestInstallationMethod = .firstBootRootJob,
                bootstrapAccountPolicy: SandboxGuestBootstrapAccountPolicy = .neverProvisioned,
                phase: SandboxGuestInstallationPhase, payload: SandboxGuestPayloadIdentity,
                guestOperatingSystemVersion: String, guestArchitecture: String,
                virtualizedRootObserved: Bool, signedInstallerVerified: Bool,
                installerExitCode: Int32? = nil, installedPayloadVerified: Bool? = nil,
                bootstrapAccountAbsent: Bool? = nil, tenantIdentityVerified: Bool? = nil) {
        self.schemaVersion = schemaVersion; self.source = source; self.rootJobID = rootJobID
        self.method = method; self.bootstrapAccountPolicy = bootstrapAccountPolicy; self.phase = phase
        self.payload = payload; self.guestOperatingSystemVersion = guestOperatingSystemVersion
        self.guestArchitecture = guestArchitecture; self.virtualizedRootObserved = virtualizedRootObserved
        self.signedInstallerVerified = signedInstallerVerified; self.installerExitCode = installerExitCode
        self.installedPayloadVerified = installedPayloadVerified; self.bootstrapAccountAbsent = bootstrapAccountAbsent
        self.tenantIdentityVerified = tenantIdentityVerified
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, source, rootJobID, method, bootstrapAccountPolicy, phase, payload
        case guestOperatingSystemVersion, guestArchitecture, virtualizedRootObserved, signedInstallerVerified
        case installerExitCode, installedPayloadVerified, bootstrapAccountAbsent, tenantIdentityVerified
    }
    private enum LegacyKey: String, CodingKey { case bootstrapRetired }

    public init(from decoder: Decoder) throws {
        let legacy = try decoder.container(keyedBy: LegacyKey.self)
        guard !legacy.contains(.bootstrapRetired) else {
            throw DecodingError.dataCorruptedError(forKey: .bootstrapRetired, in: legacy,
                debugDescription: "Accountless evidence cannot claim legacy bootstrap retirement")
        }
        let value = try decoder.container(keyedBy: CodingKeys.self)
        self.init(schemaVersion: try value.decode(Int.self, forKey: .schemaVersion),
            source: try value.decode(SandboxGuestBaseSource.self, forKey: .source),
            rootJobID: try value.decode(UUID.self, forKey: .rootJobID),
            method: try value.decode(SandboxGuestInstallationMethod.self, forKey: .method),
            bootstrapAccountPolicy: try value.decode(SandboxGuestBootstrapAccountPolicy.self, forKey: .bootstrapAccountPolicy),
            phase: try value.decode(SandboxGuestInstallationPhase.self, forKey: .phase),
            payload: try value.decode(SandboxGuestPayloadIdentity.self, forKey: .payload),
            guestOperatingSystemVersion: try value.decode(String.self, forKey: .guestOperatingSystemVersion),
            guestArchitecture: try value.decode(String.self, forKey: .guestArchitecture),
            virtualizedRootObserved: try value.decode(Bool.self, forKey: .virtualizedRootObserved),
            signedInstallerVerified: try value.decode(Bool.self, forKey: .signedInstallerVerified),
            installerExitCode: try value.decodeIfPresent(Int32.self, forKey: .installerExitCode),
            installedPayloadVerified: try value.decodeIfPresent(Bool.self, forKey: .installedPayloadVerified),
            bootstrapAccountAbsent: try value.decodeIfPresent(Bool.self, forKey: .bootstrapAccountAbsent),
            tenantIdentityVerified: try value.decodeIfPresent(Bool.self, forKey: .tenantIdentityVerified))
    }

    public var isValidStartedRecord: Bool {
        schemaVersion == 2 && source.isValid && source.kind == .appleRestore
            && method == .firstBootRootJob && bootstrapAccountPolicy == .neverProvisioned
            && payload.isValid && SandboxGuestReceiptPolicy.isGuestOS(guestOperatingSystemVersion)
            && guestArchitecture == "arm64" && virtualizedRootObserved
            && (installerExitCode.map { (0...255).contains($0) } ?? true)
    }

    public var installationComplete: Bool {
        isValidStartedRecord && phase == .installationComplete && signedInstallerVerified && installerExitCode == 0
            && installedPayloadVerified == true && bootstrapAccountAbsent == true && tenantIdentityVerified == true
    }
}

enum SandboxGuestReceiptPolicy {
    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func isName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        func alphaNumeric(_ byte: UInt8) -> Bool { (97...122).contains(byte) || (48...57).contains(byte) }
        return (1...63).contains(bytes.count) && bytes.first.map(alphaNumeric) == true
            && bytes.last.map(alphaNumeric) == true && bytes.allSatisfy { alphaNumeric($0) || $0 == 45 }
    }
    static func isGuestOS(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count < 64 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
