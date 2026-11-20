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
public enum LocationOverride: String, CaseIterable, Sendable {
    case daemonStateFile = "DARKBLOOM_STATE_FILE"
    case loadedModelsFile = "DARKBLOOM_LOADED_MODELS_FILE"
    case verifiedWeightsFile = "DARKBLOOM_VERIFIED_WEIGHTS_FILE"
    case pidFile = "DARKBLOOM_PID_FILE"
    case watchdogState = "DARKBLOOM_WATCHDOG_STATE"
    case kvBackendGuard = "DARKBLOOM_KV_BACKEND_GUARD"
    case authTokenPath = "DARKBLOOM_AUTH_TOKEN_PATH"
    case localDirectory = "DARKBLOOM_LOCAL_DIR"
    case modelCDN = "DARKBLOOM_R2_CDN_URL"

    public var environmentKey: String { rawValue }

    /// Tests stand in for a release build (`false`) or a debug build (`true`).
    @TaskLocal static var readsEnvironmentForTesting: Bool?

    /// Whether this build reads the variables.
    public static var readsEnvironmentInThisBuild: Bool {
        if let readsEnvironmentForTesting { return readsEnvironmentForTesting }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private static let assignments = OSAllocatedUnfairLock<[LocationOverride: String]>(initialState: [:])

    /// The value this process assigned; else, where `readsEnvironment`, the
    /// variable's non-empty value; else nil, meaning the default location.
    public func value(environment: [String: String] = ProcessInfo.processInfo.environment,
                      readsEnvironment: Bool = LocationOverride.readsEnvironmentInThisBuild,
                      assigned: [LocationOverride: String]? = nil) -> String? {
        let assigned = assigned ?? Self.assignments.withLock { $0 }
        if let value = assigned[self] { return value }
        guard readsEnvironment, let value = environment[environmentKey], !value.isEmpty else { return nil }
        return value
    }

    /// Sets this location for the rest of the process, in every build. Never
    /// from a test process that runs other suites: tests pass `assigned:`.
    public func assign(_ value: String) {
        Self.assignments.withLock { $0[self] = value }
    }
}
