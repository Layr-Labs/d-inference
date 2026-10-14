import Foundation

/// Default coordinator, model CDN and install identity, fixed when the binary
/// is compiled.
///
/// Package.swift defines DARKBLOOM_ENV_DEV for this target when the release
/// workflow builds with DARKBLOOM_RELEASE_ENVIRONMENT=dev. Every other build,
/// including local `swift build` and all tests, uses production values.
/// provider.toml, CLI flags and DARKBLOOM_R2_CDN_URL still override the
/// coordinator and CDN defaults.
///
/// ## Install identity
///
/// A dev install and a production install can run on the same Mac. They do
/// not share a path, a port, a launchd label or a keychain item:
///
/// | Property                | prod                     | dev                          |
/// |-------------------------|--------------------------|------------------------------|
/// | `cliName`               | `darkbloom`              | `darkbloom-dev`              |
/// | `enclaveName`           | `darkbloom-enclave`      | `darkbloom-enclave-dev`      |
/// | `appBundleName`         | `Darkbloom.app`          | `Darkbloom Dev.app`          |
/// | `installDirectoryName`  | `.darkbloom`             | `.darkbloom-dev`             |
/// | `configDirectoryName`   | `.config/darkbloom`      | `.config/darkbloom-dev`      |
/// | `launchAgentLabel`      | `io.darkbloom.provider`  | `io.darkbloom.provider.dev`  |
/// | `watchdogAgentLabel`    | `io.darkbloom.watchdog`  | `io.darkbloom.watchdog.dev`  |
/// | `logSubsystem`          | `com.darkbloom.provider` | `com.darkbloom.provider.dev` |
/// | `serviceLogSubsystem`   | `dev.darkbloom.provider` | `dev.darkbloom.provider.dev` |
/// | `defaultBackendPort`    | `8100`                   | `8101`                       |
/// | `keychainServicePrefix` | `io.darkbloom`           | `io.darkbloom.dev`           |
///
/// Paths are relative to the home directory. Only production also reads the
/// legacy `.config/eigeninference` directory.
///
/// ## Shared on purpose
///
/// These values are NOT part of the install identity. Both environments use
/// the same value, because the Developer ID signature, the provisioning
/// profile, notarization and App Attest check them:
///
/// - the code-signing identifier and bundle identifier `io.darkbloom.provider`
///   (`SignedReleaseIdentity.identifier`, `WorkerPeerIdentity.signingID`,
///   `DarkbloomCodeSignature.bundleIdentifier`),
/// - the keychain access group `SLDQ2GJ6TL.io.darkbloom.provider`
///   (`PersistentEnclaveKey.defaultAccessGroup`, an entitlement),
/// - the MDM profile identifiers (`DarkbloomMDMRemoval`),
/// - the fan helper identifier `io.darkbloom.fan-helper` and its system
///   launchd service `io.darkbloom.fan`.
///
/// Do not make these values depend on the environment. A dev value would not
/// match the signed bundle, and the keychain or App Attest would refuse it.
public enum BuildEnvironment: String, Sendable, CaseIterable {
    case prod
    case dev

    #if DARKBLOOM_ENV_DEV
    public static let current: BuildEnvironment = .dev
    #else
    public static let current: BuildEnvironment = .prod
    #endif

    public var coordinatorHTTPURL: String {
        switch self {
        case .prod: return "https://api.darkbloom.dev"
        case .dev: return "https://api.dev.darkbloom.dev"
        }
    }

    public var coordinatorWebSocketURL: String {
        switch self {
        case .prod: return "wss://api.darkbloom.dev/ws/provider"
        case .dev: return "wss://api.dev.darkbloom.dev/ws/provider"
        }
    }

    /// Must equal the coordinator's MODEL_REGISTRY_CDN_BASE_URL for the same
    /// environment. Dev reads the production CDN, read only.
    public var modelCDNURL: String {
        switch self {
        case .prod, .dev: return "https://models.darkbloom.ai"
        }
    }

    // MARK: - Install identity

    /// Name of the provider CLI: the executable in the app and the `bin/` link.
    public var cliName: String {
        switch self {
        case .prod: return "darkbloom"
        case .dev: return "darkbloom-dev"
        }
    }

    /// Name of the Secure Enclave helper executable and its `bin/` link.
    public var enclaveName: String {
        switch self {
        case .prod: return "darkbloom-enclave"
        case .dev: return "darkbloom-enclave-dev"
        }
    }

    /// Name of the signed app bundle in the install directory.
    public var appBundleName: String {
        switch self {
        case .prod: return "Darkbloom.app"
        case .dev: return "Darkbloom Dev.app"
        }
    }

    /// Install and data directory, relative to the home directory.
    public var installDirectoryName: String {
        switch self {
        case .prod: return ".darkbloom"
        case .dev: return ".darkbloom-dev"
        }
    }

    /// Configuration directory, relative to the home directory.
    public var configDirectoryName: String {
        switch self {
        case .prod: return ".config/darkbloom"
        case .dev: return ".config/darkbloom-dev"
        }
    }

    /// Configuration directories from earlier product names. Only production
    /// has them.
    public var legacyConfigDirectoryNames: [String] {
        switch self {
        case .prod: return [".config/eigeninference"]
        case .dev: return []
        }
    }

    /// launchd label of the provider LaunchAgent.
    public var launchAgentLabel: String {
        switch self {
        case .prod: return "io.darkbloom.provider"
        case .dev: return "io.darkbloom.provider.dev"
        }
    }

    /// launchd label of the crash-recovery watchdog LaunchAgent.
    public var watchdogAgentLabel: String {
        switch self {
        case .prod: return "io.darkbloom.watchdog"
        case .dev: return "io.darkbloom.watchdog.dev"
        }
    }

    /// Unified logging subsystem of the engine and the KV cache.
    public var logSubsystem: String {
        switch self {
        case .prod: return "com.darkbloom.provider"
        case .dev: return "com.darkbloom.provider.dev"
        }
    }

    /// Unified logging subsystem of the provider service. `logs` and `report`
    /// read this subsystem.
    public var serviceLogSubsystem: String {
        switch self {
        case .prod: return "dev.darkbloom.provider"
        case .dev: return "dev.darkbloom.provider.dev"
        }
    }

    /// Default port of the local inference backend.
    public var defaultBackendPort: UInt16 {
        switch self {
        case .prod: return 8100
        case .dev: return 8101
        }
    }

    /// Prefix of keychain service names and key labels that this install
    /// owns. The keychain access group does not change (see above).
    public var keychainServicePrefix: String {
        switch self {
        case .prod: return "io.darkbloom"
        case .dev: return "io.darkbloom.dev"
        }
    }

    /// `~/<installDirectoryName>`.
    public func installDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(installDirectoryName, isDirectory: true)
    }

    /// `~/<configDirectoryName>`.
    public func configDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(configDirectoryName, isDirectory: true)
    }
}
