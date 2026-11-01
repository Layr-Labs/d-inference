import Foundation

/// Default coordinator, model CDN and install identity, fixed when the binary
/// is compiled.
///
/// Package.swift defines DARKBLOOM_ENV_DEV for this target when the release
/// workflow builds with DARKBLOOM_RELEASE_ENVIRONMENT=dev, and
/// DARKBLOOM_ENV_STAGING for DARKBLOOM_RELEASE_ENVIRONMENT=staging. With the
/// variable unset, Package.swift picks its branch default: production on
/// master, dev on the dev branch. CI and the release qualification set prod,
/// so the tests see production values on every branch.
/// provider.toml, CLI flags and DARKBLOOM_R2_CDN_URL still override the
/// coordinator and CDN defaults.
///
/// ## Install identity
///
/// `provider-swift/identity/provider-identity.json` is the only declaration of
/// the values. `scripts/generate-provider-identity.py` writes them into
/// `Identity.generated.swift` (the properties `cliName`, `enclaveName`,
/// `appBundleName`, `installDirectoryName`, `launchAgentLabel`,
/// `defaultLocalPort`, `keychainServicePrefix` and the others), and
/// `scripts/test-provider-identity.py` fails when the two differ. A dev install
/// and a production install can run on the same Mac: they do not share a path,
/// a port, a launchd label or a keychain item.
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
    case staging

    #if DARKBLOOM_ENV_DEV
    public static let current: BuildEnvironment = .dev
    #elseif DARKBLOOM_ENV_STAGING
    public static let current: BuildEnvironment = .staging
    #else
    public static let current: BuildEnvironment = .prod
    #endif

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
