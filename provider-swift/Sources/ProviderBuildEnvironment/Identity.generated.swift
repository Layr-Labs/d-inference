// Generated from provider-swift/identity/provider-identity.json by scripts/generate-provider-identity.py.
// Do not edit. Change the JSON and run the script again.

extension BuildEnvironment {
    /// Default coordinator HTTP base URL.
    public var coordinatorHTTPURL: String {
        switch self {
        case .prod: return "https://api.darkbloom.dev"
        case .dev: return "https://api.dev.darkbloom.dev"
        case .staging: return "https://api.staging.darkbloom.dev"
        }
    }

    /// Default coordinator provider WebSocket URL.
    public var coordinatorWebSocketURL: String {
        switch self {
        case .prod: return "wss://api.darkbloom.dev/ws/provider"
        case .dev: return "wss://api.dev.darkbloom.dev/ws/provider"
        case .staging: return "wss://api.staging.darkbloom.dev/ws/provider"
        }
    }

    /// Must equal the coordinator's MODEL_REGISTRY_CDN_BASE_URL for the same
    /// environment. Dev reads the production CDN, read only.
    public var modelCDNURL: String {
        switch self {
        case .prod: return "https://models.darkbloom.ai"
        case .dev: return "https://models.darkbloom.ai"
        case .staging: return "https://models.darkbloom.ai"
        }
    }

    /// Name of the provider CLI: the executable in the app and the `bin/` link.
    public var cliName: String {
        switch self {
        case .prod: return "darkbloom"
        case .dev: return "darkbloom-dev"
        case .staging: return "darkbloom-staging"
        }
    }

    /// Name of the Secure Enclave helper executable and its `bin/` link.
    public var enclaveName: String {
        switch self {
        case .prod: return "darkbloom-enclave"
        case .dev: return "darkbloom-enclave-dev"
        case .staging: return "darkbloom-enclave-staging"
        }
    }

    /// Name of the signed app bundle in the install directory.
    public var appBundleName: String {
        switch self {
        case .prod: return "Darkbloom.app"
        case .dev: return "Darkbloom Dev.app"
        case .staging: return "Darkbloom Staging.app"
        }
    }

    /// `CFBundleName` of the signed app bundle.
    public var appDisplayName: String {
        switch self {
        case .prod: return "Darkbloom"
        case .dev: return "Darkbloom Dev"
        case .staging: return "Darkbloom Staging"
        }
    }

    /// Install and data directory, relative to the home directory.
    public var installDirectoryName: String {
        switch self {
        case .prod: return ".darkbloom"
        case .dev: return ".darkbloom-dev"
        case .staging: return ".darkbloom-staging"
        }
    }

    /// Configuration directory, relative to the home directory.
    public var configDirectoryName: String {
        switch self {
        case .prod: return ".config/darkbloom"
        case .dev: return ".config/darkbloom-dev"
        case .staging: return ".config/darkbloom-staging"
        }
    }

    /// Configuration directories from earlier product names.
    public var legacyConfigDirectoryNames: [String] {
        switch self {
        case .prod: return [".config/eigeninference"]
        case .dev: return []
        case .staging: return []
        }
    }

    /// launchd label of the provider LaunchAgent.
    public var launchAgentLabel: String {
        switch self {
        case .prod: return "io.darkbloom.provider"
        case .dev: return "io.darkbloom.provider.dev"
        case .staging: return "io.darkbloom.provider.staging"
        }
    }

    /// launchd label of the crash-recovery watchdog LaunchAgent.
    public var watchdogAgentLabel: String {
        switch self {
        case .prod: return "io.darkbloom.watchdog"
        case .dev: return "io.darkbloom.watchdog.dev"
        case .staging: return "io.darkbloom.watchdog.staging"
        }
    }

    /// Unified logging subsystem of the engine and the KV cache.
    public var logSubsystem: String {
        switch self {
        case .prod: return "com.darkbloom.provider"
        case .dev: return "com.darkbloom.provider.dev"
        case .staging: return "com.darkbloom.provider.staging"
        }
    }

    /// Unified logging subsystem of the provider service. `logs` and `report`
    /// read this subsystem.
    public var serviceLogSubsystem: String {
        switch self {
        case .prod: return "dev.darkbloom.provider"
        case .dev: return "dev.darkbloom.provider.dev"
        case .staging: return "dev.darkbloom.provider.staging"
        }
    }

    /// Default port of the direct-mode local OpenAI endpoint (`start --local`).
    public var defaultLocalPort: UInt16 {
        switch self {
        case .prod: return 8000
        case .dev: return 8001
        case .staging: return 8002
        }
    }

    /// Prefix of keychain service names and key labels that this install owns.
    /// The keychain access group does not change.
    public var keychainServicePrefix: String {
        switch self {
        case .prod: return "io.darkbloom"
        case .dev: return "io.darkbloom.dev"
        case .staging: return "io.darkbloom.staging"
        }
    }

    /// Directory of this install's encrypted KV cache, in the user cache
    /// directory or in the configured cache directory. Downloaded model
    /// weights are not in it; both installs share them.
    public var encryptedCacheNamespace: String {
        switch self {
        case .prod: return "darkbloom"
        case .dev: return "darkbloom-dev"
        case .staging: return "darkbloom-staging"
        }
    }

    /// Name of this install's active-revision ref (`refs/<name>`) in the shared
    /// model weights cache. Each install selects its own revision of the shared
    /// weights; a missing ref falls back to production's selection.
    public var modelRevisionRef: String {
        switch self {
        case .prod: return "main"
        case .dev: return "darkbloom-dev"
        case .staging: return "darkbloom-staging"
        }
    }
}
