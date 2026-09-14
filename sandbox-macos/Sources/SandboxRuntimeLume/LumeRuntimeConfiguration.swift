import Foundation
import SandboxRuntime
import HostRuntimeCoordination

public enum LumeRuntimeTrustPolicy: Sendable {
    case production
    case developmentAdHoc
}

package enum LumeGuestCommandPolicy: Sendable {
    case disabled
    case baseImagePreparationAndDevelopment
    case isolatedAgent
}

public struct LumeRuntimeConfiguration: Sendable {
    public static let pinnedRepository = "https://github.com/trycua/cua.git"
    public static let pinnedCommit = "737dc2a069528abadee67526d138a907e1c52061"
    public static let pinnedSourcePath = "libs/lume"
    public static let pinnedVersion = "0.5.3"
    public static let pinnedPatchPath =
        "ThirdParty/lume-patches/0001-bound-ssh-command-output.patch"
    public static let pinnedPatchSHA256 =
        "4d10399041b64a60ebde176009ffff761235cc1e70013b7e1549a2c79a34a430"
    public static let pinnedLivenessPatchPath =
        "ThirdParty/lume-patches/0002-fail-closed-run-lock-liveness.patch"
    public static let pinnedLivenessPatchSHA256 =
        "135c94920e4a773b13f1e057e0198a82ffa2d8b1cced0cd23782da84a3ba788a"
    public static let pinnedRunLockIdentityPatchPath =
        "ThirdParty/lume-patches/0003-bind-run-lock-identity.patch"
    public static let pinnedRunLockIdentityPatchSHA256 =
        "189c2b7f3e0adde5966e15e7403ed7657cedfff60208102590e0eac6b524f3b7"
    public static let pinnedBrokerLifecyclePatchPath =
        "ThirdParty/lume-patches/0004-broker-lifecycle-capability.patch"
    public static let pinnedBrokerLifecyclePatchSHA256 =
        "622b7ccee3a2d842e8aad83fe26ce4e1ab4027bd585a10ffddc40d416e288026"
    public static let pinnedIsolationPatchPath =
        "ThirdParty/lume-patches/0005-isolate-tenant-devices-and-guest-channel.patch"
    public static let pinnedIsolationPatchSHA256 =
        "4fba4b7ec0fa7554ce47e84163b46e12cdf98bb6ece60fb83baf3940cbe165c9"
    public static let pinnedRuntimeOwnershipPatchPath =
        "ThirdParty/lume-patches/0006-retain-machine-ownership-and-canonical-paths.patch"
    public static let pinnedRuntimeOwnershipPatchSHA256 =
        "49f918683d2b69f8213cedfa2c7482e9bda655c156976023c95a9d8dfd0af834"
    public static let pinnedFailureDiagnosticPatchPath = "ThirdParty/lume-patches/0007-report-owner-fail-stop-without-buffering.patch"
    public static let pinnedFailureDiagnosticPatchSHA256 = "175352985a63ba818926c36604d79dc89e5e457cd369292365544c83657e66a5"
    public static let pinnedStopCoalescingPatchPath = "ThirdParty/lume-patches/0008-coalesce-native-virtual-machine-stop.patch"
    public static let pinnedStopCoalescingPatchSHA256 = "28896292d17137e6e20d17f0d86413dcd31c2b93365042af09be4d3a45887096"

    public static let pinnedManagedRestorePatchPath = "ThirdParty/lume-patches/0009-bound-managed-apple-restores.patch"
    public static let pinnedManagedRestorePatchSHA256 = "d8b710292632def0c987ca7a70b7e53c0f8452f17250823963f133e1525aa861"

    public static let pinnedGuestEndpointCleanupPatchPath = "ThirdParty/lume-patches/0010-unlink-owned-guest-endpoint-before-stop-returns.patch"
    public static let pinnedGuestEndpointCleanupPatchSHA256 = "6abb6aa1cb582fe0157fc147159a0168160d1e79f39d3df8d40b96bbbade07ca"

    public static let pinnedRelayFixturePatchPath = "ThirdParty/lume-patches/0011-await-relay-fixture-io-without-blocking-test-executors.patch"
    public static let pinnedRelayFixturePatchSHA256 = "45f6324e1eac2adcc09e7462d14bf37d3ef216c74c109e369fc1c8b3c9fd009b"

    public static let pinnedPatches = [
        pinnedPatchPath: pinnedPatchSHA256,
        pinnedLivenessPatchPath: pinnedLivenessPatchSHA256,
        pinnedRunLockIdentityPatchPath: pinnedRunLockIdentityPatchSHA256,
        pinnedBrokerLifecyclePatchPath: pinnedBrokerLifecyclePatchSHA256,
        pinnedIsolationPatchPath: pinnedIsolationPatchSHA256,
        pinnedRuntimeOwnershipPatchPath: pinnedRuntimeOwnershipPatchSHA256,
        pinnedFailureDiagnosticPatchPath: pinnedFailureDiagnosticPatchSHA256,
        pinnedStopCoalescingPatchPath: pinnedStopCoalescingPatchSHA256,
        pinnedManagedRestorePatchPath: pinnedManagedRestorePatchSHA256,
        pinnedGuestEndpointCleanupPatchPath: pinnedGuestEndpointCleanupPatchSHA256,
        pinnedRelayFixturePatchPath: pinnedRelayFixturePatchSHA256,
    ]

    public let executable: URL
    public let storageDirectory: URL
    public let commandTimeoutSeconds: UInt32
    public let createTimeoutSeconds: UInt32
    public let trustPolicy: LumeRuntimeTrustPolicy
    public let isolatedGuest: LumeGuestMaterialConfiguration?
    public let hostRuntimeLease: HostRuntimeLease?
    package let guestCommandPolicy: LumeGuestCommandPolicy
    package let baseImageSharedDirectory: URL?

    public init(
        executable: URL,
        storageDirectory: URL,
        commandTimeoutSeconds: UInt32 = 60,
        createTimeoutSeconds: UInt32 = 7_200,
        trustPolicy: LumeRuntimeTrustPolicy = .production,
        isolatedGuest: LumeGuestMaterialConfiguration? = nil,
        hostRuntimeLease: HostRuntimeLease? = nil
    ) throws {
        try self.init(
            executable: executable,
            storageDirectory: storageDirectory,
            commandTimeoutSeconds: commandTimeoutSeconds,
            createTimeoutSeconds: createTimeoutSeconds,
            trustPolicy: trustPolicy,
            guestCommandPolicy: isolatedGuest == nil ? .disabled : .isolatedAgent,
            isolatedGuest: isolatedGuest,
            hostRuntimeLease: hostRuntimeLease
        )
    }

    package init(
        executable: URL,
        storageDirectory: URL,
        commandTimeoutSeconds: UInt32 = 60,
        createTimeoutSeconds: UInt32 = 7_200,
        trustPolicy: LumeRuntimeTrustPolicy = .production,
        guestCommandPolicy: LumeGuestCommandPolicy,
        isolatedGuest: LumeGuestMaterialConfiguration? = nil,
        baseImageSharedDirectory: URL? = nil,
        hostRuntimeLease: HostRuntimeLease? = nil
    ) throws {
        guard executable.isFileURL,
              executable.baseURL == nil,
              storageDirectory.isFileURL,
              storageDirectory.baseURL == nil,
              storageDirectory.path.hasPrefix("/"),
              commandTimeoutSeconds > 0,
              createTimeoutSeconds >= commandTimeoutSeconds
        else {
            throw SandboxRuntimeError.unsupported(
                "Lume configuration requires absolute paths and positive timeouts"
            )
        }
        self.executable = executable
            .standardizedFileURL
            .resolvingSymlinksInPath()
        self.storageDirectory = storageDirectory.standardizedFileURL
        self.commandTimeoutSeconds = commandTimeoutSeconds
        self.createTimeoutSeconds = createTimeoutSeconds
        self.trustPolicy = trustPolicy
        self.guestCommandPolicy = guestCommandPolicy
        self.isolatedGuest = isolatedGuest
        self.hostRuntimeLease = hostRuntimeLease
        if let directory = baseImageSharedDirectory {
            guard guestCommandPolicy == .baseImagePreparationAndDevelopment,
                  isolatedGuest == nil, directory.isFileURL, directory.baseURL == nil,
                  directory.path.hasPrefix("/"), !directory.path.contains(":"),
                  !directory.path.contains("\0"),
                  directory.standardizedFileURL.resolvingSymlinksInPath().path == directory.path else {
                throw SandboxRuntimeError.unsupported("invalid base-image bootstrap share")
            }
        }
        self.baseImageSharedDirectory = baseImageSharedDirectory
    }
}
