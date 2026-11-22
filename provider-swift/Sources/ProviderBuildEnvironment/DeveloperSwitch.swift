import Foundation

/// The environment variables that exist for tests, development and
/// qualification, each with the builds that honour it.
///
/// A variable declared here is spelled in no other provider source and is
/// read with `value(environment:posture:)`, which answers nil for a build
/// that does not honour it. "A release build ignores X" is therefore this
/// declaration and one table test (`DeveloperSwitchTests`), not a check at
/// each place X is read. The same tests read the sources. They fail when a
/// variable is not a case here and `LaunchAgent.unforwardedEnvKeyGroups`
/// declares it `debugOnly` or `pathOverride`, or it does not reach the
/// service and its name says DEBUG, DEV, DEVELOPER or TEST. They fail when
/// a case's variable is spelled anywhere else, and when an environment is
/// read through a constant that holds `environmentKey`.
///
/// The declaration decides what a build honours; an `#if DEBUG` block
/// decides what a build contains. A read that must not exist in a release
/// binary (a key file, a certificate pin, an extra signing identity) stays
/// inside its block.
public enum DeveloperSwitch: String, CaseIterable, Sendable {
    // MARK: Debug builds only

    /// One extra signing identity for the sandbox add-on (`AddonPeerPolicy`).
    case addonDevIdentity = "DARKBLOOM_ADDON_DEV_IDENTITY"
    /// An operator's key file in place of the keychain's SSD cache key (`SSDDebugCacheKeyFile`).
    case debugCacheKeyFile = "DARKBLOOM_DEBUG_CACHE_KEY_FILE"
    /// A shorter absence grace before a pair member serves alone (`ClusterControlSoloGrace`).
    case debugClusterSoloGraceSeconds = "DARKBLOOM_DEBUG_CLUSTER_SOLO_GRACE_SECONDS"
    /// A local test coordinator's certificate, pinned (`CoordinatorDebugCertificatePin`).
    case debugCoordinatorCertSHA256 = "DARKBLOOM_DEBUG_COORDINATOR_CERT_SHA256"
    /// A harness wrapper in place of the installed owner executable (`ClusterSetupWizardLiveOperations.ownerExecutable`).
    case debugOwnerExecutable = "DARKBLOOM_DEBUG_OWNER_EXECUTABLE"
    /// A roster accepted without the pairing (`ClusterMemberPreparation.rosterWithoutPairingAllowed`).
    case debugRosterUnpaired = "DARKBLOOM_DEBUG_ROSTER_UNPAIRED"
    /// A Secure Enclave key kept in a file (`SecureEnclaveIdentity.debugPersisted`).
    case debugSEKeyFile = "DARKBLOOM_DEBUG_SE_KEY_FILE"
    /// Another keychain access group (`KeychainAccessGroup`).
    case keychainAccessGroup = "DARKBLOOM_KEYCHAIN_ACCESS_GROUP"
    // The planner's developer overrides. A release build refuses to plan
    // while one is set (`ClusterForcedModeSetting`, `ClusterBenchChip`,
    // `ClusterPlannerBenchCap`).
    case clusterForceMode = "DARKBLOOM_CLUSTER_FORCE_MODE"
    case devBenchChip = "DARKBLOOM_DEV_BENCH_CHIP"
    case devBenchPlannerCapGiB = "DARKBLOOM_DEV_BENCH_PLANNER_CAP_GIB"
    // The provider's state files and its model mirror (`LocationOverride`,
    // whose cases carry the same names).
    case daemonStateFile = "DARKBLOOM_STATE_FILE"
    case loadedModelsFile = "DARKBLOOM_LOADED_MODELS_FILE"
    case verifiedWeightsFile = "DARKBLOOM_VERIFIED_WEIGHTS_FILE"
    case pidFile = "DARKBLOOM_PID_FILE"
    case watchdogState = "DARKBLOOM_WATCHDOG_STATE"
    case kvBackendGuard = "DARKBLOOM_KV_BACKEND_GUARD"
    case authTokenPath = "DARKBLOOM_AUTH_TOKEN_PATH"
    case localDirectory = "DARKBLOOM_LOCAL_DIR"
    case modelCDN = "DARKBLOOM_R2_CDN_URL"

    // MARK: Every build but production's

    /// A setup that reaches the other Mac over SSH may serve (`DistributedInstalledDeveloperSSH`).
    case clusterDeveloperSSH = "DARKBLOOM_CLUSTER_DEVELOPER_SSH"

    // MARK: Every build, undecided

    /// Moves the cluster supervisor's state file (`ClusterSupervisionFiles.statePath`).
    case clusterSupervisorState = "DARKBLOOM_CLUSTER_SUPERVISOR_STATE"
    /// Moves the desktop service's directory, which holds the account token (`DesktopStorage.directory`).
    case desktopDirectory = "DARKBLOOM_DESKTOP_DIR"
    /// Moves the add-on socket and, with it, the machine lock the provider observes (`AddonHoldPaths.production`).
    case addonSocket = "DARKBLOOM_ADDON_SOCKET"
    /// Moves a pair rank's SSD prefix records (`DistributedInstalledPrefixSSD.environment`).
    case clusterPrefixSSDDirectory = "DARKBLOOM_CLUSTER_PREFIX_SSD_DIR"
    /// Allows the SSD tier an in-memory key, and opts in to the two test switches below (`SSDPrefixCacheFactory.ephemeralAllowed`).
    case prefixCacheAllowEphemeral = "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL"
    /// Moves the SSD tier's root (`SSDPrefixCacheFactory.isolatedTestRoot`).
    case prefixCacheTestRoot = "DARKBLOOM_PREFIX_CACHE_TEST_ROOT"
    /// Keeps the keychain's key under a test root (`SSDPrefixCacheFactory.forceEphemeralKey`).
    case prefixCacheTestPersistentKey = "DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY"
    /// Writes a failed local request's error text to stderr (`CORSResponder`, the local API).
    case debugLocalErrors = "DARKBLOOM_DEBUG_LOCAL_ERRORS"
    /// Moves the sandbox add-on's install root as the CLI sees it (`SandboxAddon.live`).
    case sandboxRoot = "DARKBLOOM_SANDBOX_ROOT"

    /// Which builds honour a switch, and so which axis of `BuildPosture`
    /// gates it.
    public enum Availability: Hashable, Sendable {
        /// The configuration axis: a debug build of any environment. No
        /// signed build honours it.
        case debugOnly
        /// The environment axis: every build but production's, a signed
        /// DevNet or staging build included.
        case nonProduction
        /// Not gated: production's release build honours it too.
        case everyBuild(EveryBuildReason)

        public func honours(_ posture: BuildPosture) -> Bool {
            switch self {
            case .debugOnly: posture.isDebug
            case .nonProduction: !posture.isProduction
            case .everyBuild: true
            }
        }
    }

    /// Why production's release build honours a switch.
    public enum EveryBuildReason: String, CaseIterable, Sendable {
        /// Open decision. The switch is a test location or a diagnosis
        /// control, and nothing gates it. Gating it changes what a release
        /// build does and can break a qualification run that sets it, so each
        /// move to `debugOnly` or `nonProduction` is a maintainer's decision.
        /// Never add to this case: a new switch is gated, or is given a
        /// reason of its own here.
        case undecided
    }

    public var environmentKey: String { rawValue }

    public var availability: Availability {
        switch self {
        case .addonDevIdentity, .debugCacheKeyFile, .debugClusterSoloGraceSeconds, .debugCoordinatorCertSHA256,
             .debugOwnerExecutable, .debugRosterUnpaired, .debugSEKeyFile, .keychainAccessGroup, .clusterForceMode,
             .devBenchChip, .devBenchPlannerCapGiB, .daemonStateFile, .loadedModelsFile, .verifiedWeightsFile, .pidFile,
             .watchdogState, .kvBackendGuard, .authTokenPath, .localDirectory, .modelCDN:
            .debugOnly
        case .clusterDeveloperSSH:
            .nonProduction
        case .clusterSupervisorState, .desktopDirectory, .addonSocket, .clusterPrefixSSDDirectory,
             .prefixCacheAllowEphemeral, .prefixCacheTestRoot, .prefixCacheTestPersistentKey, .debugLocalErrors,
             .sandboxRoot:
            .everyBuild(.undecided)
        }
    }

    public func isHonoured(by posture: BuildPosture = .current) -> Bool {
        availability.honours(posture)
    }

    /// The variable exactly as `environment` sets it (an empty value
    /// included) where `posture` honours the switch; nil where it does not,
    /// or where the variable is unset.
    public func value(environment: [String: String] = ProcessInfo.processInfo.environment,
                      posture: BuildPosture = .current) -> String? {
        isHonoured(by: posture) ? environment[environmentKey] : nil
    }

    /// The variable as set, where `posture` does not honour the switch; nil
    /// where it does, or where the variable is unset. Only for a build that
    /// refuses to run while a switch it ignores is set (the planner's
    /// developer overrides). Nothing may act on the value.
    public func ignoredValue(environment: [String: String], posture: BuildPosture = .current) -> String? {
        isHonoured(by: posture) ? nil : environment[environmentKey]
    }
}
