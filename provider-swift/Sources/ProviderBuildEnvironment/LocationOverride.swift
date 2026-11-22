import Foundation
import os

/// The environment variables that move the provider's state files and the
/// mirror it downloads model weights from. A debug build (tests, development
/// and the release workflow's SDK qualification, which runs the debug test
/// build) reads them; a release build ignores them, so it keeps its state files
/// in its install directory and downloads from its build's model CDN
/// (`BuildEnvironment.modelCDNURL`).
///
/// Code in the binary that needs other locations in a release build, such as a
/// qualification run's private state directory or a report under `sudo` that
/// reads the invoking user's files, sets them with `assign`; the environment
/// cannot.
public enum LocationOverride: CaseIterable, Sendable {
    case daemonStateFile
    case loadedModelsFile
    case verifiedWeightsFile
    case pidFile
    case watchdogState
    case kvBackendGuard
    case authTokenPath
    case localDirectory
    case modelCDN

    /// The switch that carries this location in the environment. Each is
    /// honoured by a debug build only (`DeveloperSwitch.availability`).
    public var developerSwitch: DeveloperSwitch {
        switch self {
        case .daemonStateFile: DeveloperSwitch.daemonStateFile
        case .loadedModelsFile: DeveloperSwitch.loadedModelsFile
        case .verifiedWeightsFile: DeveloperSwitch.verifiedWeightsFile
        case .pidFile: DeveloperSwitch.pidFile
        case .watchdogState: DeveloperSwitch.watchdogState
        case .kvBackendGuard: DeveloperSwitch.kvBackendGuard
        case .authTokenPath: DeveloperSwitch.authTokenPath
        case .localDirectory: DeveloperSwitch.localDirectory
        case .modelCDN: DeveloperSwitch.modelCDN
        }
    }

    public var environmentKey: String { developerSwitch.environmentKey }

    /// Tests stand in for a release build (`false`) or a debug build (`true`).
    @TaskLocal static var readsEnvironmentForTesting: Bool?

    /// Whether this build reads the variables.
    public static var readsEnvironmentInThisBuild: Bool {
        readsEnvironmentForTesting ?? BuildPosture.current.isDebug
    }

    private static let assignments = OSAllocatedUnfairLock<[LocationOverride: String]>(initialState: [:])

    /// The value this process assigned; else, where `readsEnvironment`, the
    /// variable's non-empty value; else nil, meaning the default location.
    public func value(environment: [String: String] = ProcessInfo.processInfo.environment,
                      readsEnvironment: Bool = LocationOverride.readsEnvironmentInThisBuild,
                      assigned: [LocationOverride: String]? = nil) -> String? {
        let assigned = assigned ?? Self.assignments.withLock { $0 }
        if let value = assigned[self] { return value }
        guard let value = developerSwitch.value(environment: environment, posture: BuildPosture(debug: readsEnvironment)),
              !value.isEmpty else { return nil }
        return value
    }

    /// Sets this location for the rest of the process, in every build. Never
    /// from a test process that runs other suites: tests pass `assigned:`.
    public func assign(_ value: String) {
        Self.assignments.withLock { $0[self] = value }
    }
}
