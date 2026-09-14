import Foundation

/// Each observation comes from the disposable clone through the normal
/// authenticated native channel. Installation success alone supplies none.
public struct SandboxGuestNativeChecks: Codable, Equatable, Sendable {
    public let authenticatedGuest: Bool
    public let tenantIdentity: Bool
    public let commandExecution: Bool
    public let workspaceRoundTrip: Bool
    public let protectedPathDenied: Bool
    public let controlDiskDenied: Bool
    public let restart: Bool

    public init(authenticatedGuest: Bool, tenantIdentity: Bool, commandExecution: Bool,
                workspaceRoundTrip: Bool, protectedPathDenied: Bool, controlDiskDenied: Bool, restart: Bool) {
        self.authenticatedGuest = authenticatedGuest; self.tenantIdentity = tenantIdentity
        self.commandExecution = commandExecution; self.workspaceRoundTrip = workspaceRoundTrip
        self.protectedPathDenied = protectedPathDenied; self.controlDiskDenied = controlDiskDenied; self.restart = restart
    }
    public var passed: Bool {
        authenticatedGuest && tenantIdentity && commandExecution && workspaceRoundTrip
            && protectedPathDenied && controlDiskDenied && restart
    }
}

public struct SandboxGuestQualificationCleanup: Codable, Equatable, Sendable {
    public let cloneInstallationID: UUID
    public let materialsInstanceID: UUID
    public let cloneRemoved: Bool
    public let materialsRemoved: Bool
    public let capacityReleased: Bool
    public let sourceStoppedReverified: Bool
    public let sourceUnchangedReverified: Bool

    public init(cloneInstallationID: UUID, materialsInstanceID: UUID, cloneRemoved: Bool,
                materialsRemoved: Bool, capacityReleased: Bool, sourceStoppedReverified: Bool,
                sourceUnchangedReverified: Bool) {
        self.cloneInstallationID = cloneInstallationID; self.materialsInstanceID = materialsInstanceID
        self.cloneRemoved = cloneRemoved; self.materialsRemoved = materialsRemoved
        self.capacityReleased = capacityReleased; self.sourceStoppedReverified = sourceStoppedReverified
        self.sourceUnchangedReverified = sourceUnchangedReverified
    }
    public var complete: Bool {
        cloneInstallationID == materialsInstanceID && cloneRemoved && materialsRemoved
            && capacityReleased && sourceStoppedReverified && sourceUnchangedReverified
    }
}

public struct SandboxGuestNativeQualification: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let currentProfile = "isolated-v1"
    public let version: Int
    public let profile: String
    public let qualificationID: UUID
    public let source: SandboxGuestBaseSource
    public let payload: SandboxGuestPayloadIdentity
    public let cloneName: String
    public let cloneInstallationID: UUID
    public let checks: SandboxGuestNativeChecks
    public let cleanup: SandboxGuestQualificationCleanup

    public init(version: Int = currentVersion, profile: String = currentProfile,
                qualificationID: UUID, source: SandboxGuestBaseSource, payload: SandboxGuestPayloadIdentity,
                cloneName: String, cloneInstallationID: UUID, checks: SandboxGuestNativeChecks,
                cleanup: SandboxGuestQualificationCleanup) {
        self.version = version; self.profile = profile; self.qualificationID = qualificationID
        self.source = source; self.payload = payload; self.cloneName = cloneName
        self.cloneInstallationID = cloneInstallationID; self.checks = checks; self.cleanup = cleanup
    }

    public func qualifies(_ installation: SandboxAccountlessInstallationReceipt) -> Bool {
        version == Self.currentVersion && profile == Self.currentProfile
            && installation.installationComplete && source == installation.source && payload == installation.payload
            && SandboxGuestReceiptPolicy.isName(cloneName) && cloneName != source.name
            && cloneInstallationID != source.installationID && qualificationID != source.installationID
            && qualificationID != cloneInstallationID && checks.passed && cleanup.complete
            && cleanup.cloneInstallationID == cloneInstallationID
    }
}

public struct SandboxAccountlessTemplateEvidence: Codable, Equatable, Sendable {
    public let installation: SandboxAccountlessInstallationReceipt
    public let qualification: SandboxGuestNativeQualification

    public init(installation: SandboxAccountlessInstallationReceipt, qualification: SandboxGuestNativeQualification) {
        self.installation = installation; self.qualification = qualification
    }
    public var ready: Bool { qualification.qualifies(installation) }
}
