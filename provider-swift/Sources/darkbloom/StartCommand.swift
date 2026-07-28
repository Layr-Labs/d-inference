import Foundation
import ArgumentParser
import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start the provider as a background service.",
        discussion: """
        Scans local MLX models, lets you pick which to serve, then launches
        a launchd background service. Use --model to skip the interactive picker.
        """
    )

    @OptionGroup var configOptions: ConfigOptions

    @Option(help: "Override coordinator WebSocket URL.")
    var coordinatorURL: String?

    @Option(help: "Model ID to serve (repeatable, skips interactive picker).")
    var model: [String] = []

    @Flag(help: "Serve all local models (skips interactive picker).")
    var all = false

    @Option(help: "Idle timeout in minutes before unloading the model.")
    var idleTimeout: UInt64?

    @Flag(inversion: .prefixedNo, help: .hidden)
    var foreground = false

    @Flag(help: "Run a local OpenAI-compatible HTTP server only; do not connect to the coordinator.")
    var local = false

    @Flag(help: "Serve a local OpenAI endpoint ALONGSIDE the coordinator (unified mode): same loaded models serve both the public fleet and local clients.")
    var localEndpoint = false

    @Option(help: "Local server port (used with --local / --local-endpoint).")
    var port: UInt16 = 8000

    @Option(help: "Bind address for --local / --local-endpoint (default 127.0.0.1; a tailnet IP exposes it to same-account devices, still API-key gated).")
    var bind: String = "127.0.0.1"

    @Flag(help: "Disable local API-key auth for --local / --local-endpoint (NOT recommended; trusted/airgapped use only).")
    var noAuth = false

    /// Public URL of the Darkbloom Terms of Service.
    static let termsURL = "https://darkbloom.dev/terms.html"

    /// Prints a one-line terms-of-service notice. Starting the provider is the
    /// act of acceptance — there is no separate yes/no prompt — so this is an
    /// informational notice, not a gate. Shown only for the user-facing
    /// invocation; the launchd-relaunched `--foreground` child skips it since
    /// the user already saw it when they ran `darkbloom start`.
    private func printTermsNotice() {
        print("By starting the provider, you agree to the Darkbloom Terms of Service:")
        print("  \(Start.termsURL)")
        print()
    }

    mutating func run() async throws {
        Darkbloom.ensureLogging()

        if !foreground {
            printTermsNotice()
        }

        // --local (coordinator-less) and --local-endpoint (alongside the
        // coordinator) are mutually exclusive serve modes; reject the ambiguous
        // combination rather than silently picking one.
        if local && localEndpoint {
            printError("--local and --local-endpoint are mutually exclusive: use --local for a coordinator-less local server, or --local-endpoint to serve a local endpoint alongside the coordinator.")
            throw ExitCode.failure
        }

        // GPU is required. Reject CPU fallback up-front so we never
        // come up reporting healthy and then silently churn at 0.5 tok/s.
        do {
            _ = try GPUEnforcement.requireMetal()
        } catch {
            printError("\(error)")
            throw ExitCode.failure
        }

        let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
        // Precedence: explicit --url flag > DARKBLOOM_DEV_COORDINATOR_URL (dev
        // daemon override) > config file. The env override lets the launchd
        // daemon target a dev-insecure coordinator without a --url flag.
        let effectiveCoordinator = coordinatorURL
            ?? DevInsecure.coordinatorURLOverride
            ?? snapshot.config.coordinator.url
        var effectiveConfig = snapshot.config
        if let idleTimeout {
            effectiveConfig.backend.idleTimeoutMins = idleTimeout
        }

        guard let hardware = snapshot.hardware else {
            printError("Cannot start: hardware detection failed (\(snapshot.hardwareError?.localizedDescription ?? "unknown"))")
            throw ExitCode.failure
        }

        if local {
            try await runLocalStandalone(
                snapshot: snapshot,
                config: effectiveConfig,
                hardware: hardware
            )
        } else if foreground {
            try await runForeground(
                snapshot: snapshot,
                hardware: hardware,
                config: effectiveConfig,
                coordinatorURL: effectiveCoordinator
            )
        } else {
            try await launchDaemon(
                snapshot: snapshot,
                config: effectiveConfig,
                coordinatorURL: effectiveCoordinator
            )
        }
    }

}
