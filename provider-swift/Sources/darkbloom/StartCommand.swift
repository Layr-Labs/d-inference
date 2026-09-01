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

        let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
        let effectiveCoordinator = coordinatorURL ?? snapshot.config.coordinator.url
        var effectiveConfig = snapshot.config
        if let idleTimeout {
            effectiveConfig.backend.idleTimeoutMins = idleTimeout
        }

        // These controls are process-start latches in MLX/MLXLM. Project the
        // authoritative TOML, bind the immutable default runtime metallib, and
        // only then let requireMetal() perform the first MLX touch.
        let boundMetallibHash: String?
        do {
            boundMetallibHash = try Self.prepareServeRuntime(
                settings: snapshot.config.gemmaOptimizations)
        } catch {
            printError("Cannot start: \(error)")
            throw ExitCode.failure
        }

        guard let hardware = snapshot.hardware else {
            printError("Cannot start: hardware detection failed (\(snapshot.hardwareError?.localizedDescription ?? "unknown"))")
            throw ExitCode.failure
        }
        // Diagnose once from the already-bound immutable snapshot and carry
        // this exact set through every serving mode and registration path.
        let runtimeCapabilities = ProviderRuntimeCapabilityDetector.detectPrepared(
            hardware: hardware,
            boundMetallibHash: boundMetallibHash
        )
        // One WARN per retired knob still set, BEFORE the serving-mode split:
        // `--local` builds no ProviderLoop, so emitting these from the serve
        // loop left standalone operators with no notice at all.
        for message in RetiredKnobWarnings.emit(config: effectiveConfig) {
            printError("warning: \(message)")
        }

        if local {
            try await runLocalStandalone(
                snapshot: snapshot,
                config: effectiveConfig,
                hardware: hardware,
                runtimeCapabilities: runtimeCapabilities
            )
        } else if foreground {
            try await runForeground(
                snapshot: snapshot,
                hardware: hardware,
                config: effectiveConfig,
                coordinatorURL: effectiveCoordinator,
                runtimeCapabilities: runtimeCapabilities
            )
        } else {
            try await launchDaemon(
                snapshot: snapshot,
                config: effectiveConfig,
                coordinatorURL: effectiveCoordinator,
                configPath: configOptions.config == nil ? nil : snapshot.configPath,
                runtimeCapabilities: runtimeCapabilities
            )
        }
    }

    /// Backward-compatible forwarding shim for the process-start environment
    /// projection and metallib binding. The real seam (and its ordering
    /// contract: config projection, then binding, then the first MLX touch)
    /// lives in `ServeRuntimePreparer.prepareRuntime` so `benchmark` mirrors the
    /// serve path without referencing `Start`. Tests target both seams.
    @discardableResult
    internal static func prepareServeRuntime(
        settings: GemmaOptimizationSettings,
        apply: (GemmaOptimizationSettings) throws -> Void = {
            try GemmaOptimizationEnvironment.apply($0)
        },
        bindMetallib: () -> String? = {
            bindRuntimeMetallibForMLX(from: nil)
        },
        requireMetal: () throws -> Void = {
            _ = try GPUEnforcement.requireMetal()
        }
    ) throws -> String? {
        try ServeRuntimePreparer.prepareRuntime(
            settings: settings,
            apply: apply,
            bindMetallib: bindMetallib,
            requireMetal: requireMetal
        )
    }

}
