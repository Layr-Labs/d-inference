import Foundation

/// The local foreground command is intentionally separate from launchd/network
/// onboarding. Keep this argv aligned with Start.run / runLocalStandalone.
enum LocalAPIStartCommand {
    static func arguments(modelID: String) -> [String] {
        ["start", "--local", "--model", modelID, "--no-replace"]
    }

    static func display(modelID: String) -> String {
        "darkbloom start --local --model " + shellQuote(modelID) + " --no-replace"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

enum LocalAPIStartConflict: Equatable, Sendable {
    case localEndpoint
    case providerRunning
    case providerTransitioning
    case providerStateUncertain

    var message: String {
        switch self {
        case .localEndpoint:
            "A local endpoint already belongs to a running process. Use that endpoint or open the existing provider controls before starting another session."
        case .providerRunning:
            "A provider is already running or managed by launchd. Open the existing provider controls to choose whether to stop it before starting local-only AI."
        case .providerTransitioning:
            "The provider is starting, stopping, or restarting. Wait for that operation to finish, then check again."
        case .providerStateUncertain:
            "The provider’s process state could not be confirmed. Check the existing provider controls or Diagnostics before starting another process."
        }
    }
}

enum LocalAPIStartError: Error, Equatable, LocalizedError, Sendable {
    case fixtureMode
    case nonReplacingLaunchUnavailable
    case modelNotInstalled
    case modelUnavailable(String)
    case conflict(LocalAPIStartConflict)
    case cli(ProviderCLIError)
    case launchFailed(String)
    case processExited
    case shutdownTimedOut
    case readinessTimedOut(modelID: String)

    var errorDescription: String? {
        switch self {
        case .nonReplacingLaunchUnavailable:
            "Native local start is not enabled for this app yet. Use the existing provider controls or open Diagnostics."
        case .fixtureMode:
            "This is sample data. Native local starts are available only with a live model library and live endpoint discovery."
        case .modelNotInstalled:
            "Choose a model installed on this Mac. Refresh Models if the installation has changed."
        case .modelUnavailable(let reason): reason
        case .conflict(let conflict): conflict.message
        case .cli(let error): error.localizedDescription
        case .launchFailed(let message): "Local start failed. " + message
        case .shutdownTimedOut:
            "The app could not confirm that its local provider stopped. Keep Darkbloom open and check Diagnostics before quitting."
        case .processExited:
            "The local provider process exited. A successful command exit does not mean a foreground endpoint is running."
        case .readinessTimedOut(let modelID):
            "The local provider has not reported a verified endpoint advertising \(modelID) in time. Check Again or open Diagnostics. The process may still be starting."
        }
    }
}

enum LocalAPIStartState: Equatable, Sendable {
    case idle
    case starting(modelID: String)
    case waitingForEndpoint(modelID: String)
    case ready(modelID: String)
    case cancelling
    case cancelled
    case failed(LocalAPIStartError)

    var isWaiting: Bool {
        switch self {
        case .starting, .waitingForEndpoint: true
        default: false
        }
    }
}

struct LocalAPIStartConfiguration: Sendable {
    /// Rollout opt-out. The CLI flag, not this switch or app preflight, enforces
    /// atomic refusal to replace another provider. Every native invocation must
    /// include --no-replace; older CLIs reject that unknown flag before running.
    var nonReplacingLaunchVerified = true
    var readinessTimeout: Duration = .seconds(30)
    var pollInterval: Duration = .milliseconds(500)

    /// Must exceed the foreground runner's SIGTERM grace so its exact-identity
    /// SIGKILL escalation can complete before the parent decides whether to quit.
    var shutdownTimeout: Duration = .seconds(5)
    var waitForReadinessTimeout: @Sendable (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    }
}
