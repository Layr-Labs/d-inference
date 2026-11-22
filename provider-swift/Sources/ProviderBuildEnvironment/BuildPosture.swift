import Foundation

/// What this binary was compiled as, on two independent axes.
///
/// - `configuration`: SwiftPM's debug or release configuration. Tests,
///   development and the release workflow's SDK qualification run debug
///   builds. Every signed build is a release build, production's and DevNet's
///   alike.
/// - `environment`: the coordinator, model CDN and install identity the build
///   was compiled for (`BuildEnvironment`).
///
/// The axes do not stand in for each other. A signed DevNet build is a
/// release configuration in the `dev` environment: it ignores what only a
/// debug build honours and honours what only production ignores. The tests
/// in CI are a debug configuration in the `prod` environment: the reverse.
/// `DeveloperSwitch.Availability` names the axis each developer-only variable
/// is gated on.
///
/// The posture is fixed when the binary is compiled. Whether the running
/// image carries this project's signature is a runtime fact
/// (`DistributedInstalledHelperSignature.current`) and is not part of it.
public struct BuildPosture: Hashable, Sendable {
    public enum Configuration: String, CaseIterable, Sendable {
        case debug
        case release

        /// The only place the provider turns the compiler's `DEBUG` condition
        /// into a value. Code that must not exist in a release binary stays
        /// inside an `#if DEBUG` block; code that only needs to know which
        /// build it is asks here.
        #if DEBUG
        public static let current: Configuration = .debug
        #else
        public static let current: Configuration = .release
        #endif
    }

    public var configuration: Configuration
    public var environment: BuildEnvironment

    /// This build, unless a value is given for an axis. A function that takes
    /// its own `build:` parameter, which its tests pass, asks about
    /// `BuildPosture(environment: build)`.
    public init(configuration: Configuration = .current, environment: BuildEnvironment = .current) {
        self.configuration = configuration
        self.environment = environment
    }

    /// This build's environment in the debug (`true`) or the release
    /// configuration: for a function that takes its own `debugBuild:`.
    public init(debug: Bool) {
        self.init(configuration: debug ? .debug : .release)
    }

    public static let current = BuildPosture()

    /// Every configuration in every environment.
    public static let allCases: [BuildPosture] = Configuration.allCases.flatMap { configuration in
        BuildEnvironment.allCases.map { BuildPosture(configuration: configuration, environment: $0) }
    }

    public var isDebug: Bool { configuration == .debug }

    /// Built for the production network, in either configuration.
    public var isProduction: Bool { environment == .prod }
}
