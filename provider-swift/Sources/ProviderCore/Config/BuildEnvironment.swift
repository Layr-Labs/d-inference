/// Default coordinator and model CDN, fixed when the binary is compiled.
///
/// Package.swift defines DARKBLOOM_ENV_DEV for ProviderCore when the release
/// workflow builds with DARKBLOOM_RELEASE_ENVIRONMENT=dev. Every other build,
/// including local `swift build` and all tests, uses production values.
/// provider.toml, CLI flags and DARKBLOOM_R2_CDN_URL still override these.
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
}
