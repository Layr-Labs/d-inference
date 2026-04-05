/// ProviderManager — Manages the Rust provider binary as a subprocess.
///
/// This class wraps Foundation's `Process` to spawn, monitor, and stop the
/// `eigeninference-provider` binary. It captures stdout/stderr for status parsing,
/// auto-restarts on unexpected crashes, and sets up the same environment
/// (PATH, PYTHONHOME) that the CLI uses.
///
/// Binary resolution is delegated to CLIRunner.resolveBinaryPath() for
/// consistency — both the app and CLI use the same search order.
///
/// The provider binary is invoked as:
///   eigeninference-provider serve --coordinator <url> --model <model> --backend-port <port>

import Combine
import Foundation
import UserNotifications

/// Manages the eigeninference-provider subprocess lifecycle.
///
/// Spawns the Rust binary, captures its output, monitors for crashes,
/// and provides clean shutdown via SIGTERM/SIGKILL.
@MainActor
final class ProviderManager: ObservableObject {

    /// Whether the provider subprocess is currently running.
    @Published var isRunning = false

    /// The most recent line of output from the provider binary.
    /// StatusViewModel observes this to parse status updates.
    @Published var lastOutputLine = ""

    /// Accumulated stderr output for diagnostics.
    @Published var lastError = ""

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var autoRestartEnabled = false
    private var currentModel = ""
    private var currentCoordinatorURL = ""
    private var currentPort = 8321
    private var restartCount = 0
    private let maxRestarts = 5

    // MARK: - Binary Path Resolution

    /// Resolve the path to the eigeninference-provider binary.
    ///
    /// Uses the same resolution order as CLIRunner for consistency:
    ///   1. `~/.eigeninference/bin/eigeninference-provider` (shared install — single source of truth)
    ///   2. Adjacent to the app bundle (fallback for first-run)
    ///   3. PATH lookup (development)
    nonisolated static func resolveBinaryPath() -> String? {
        CLIRunner.resolveBinaryPath()
    }

    /// Build the full command arguments for the provider binary.
    ///
    /// Returns the arguments array: ["serve", "--coordinator", url, "--model", model, "--backend-port", port]
    nonisolated static func buildArguments(model: String, coordinatorURL: String, port: Int) -> [String] {
        return [
            "serve",
            "--coordinator", coordinatorURL,
            "--model", model,
            "--backend-port", String(port),
        ]
    }

    // MARK: - Lifecycle

    /// Start the provider subprocess.
    ///
    /// Resolves the binary path, spawns the process with the given
    /// configuration, and sets up stdout/stderr capture. Enables
    /// auto-restart on crash.
    ///
    /// - Parameters:
    ///   - model: The model identifier to serve (e.g., "mlx-community/Qwen3.5-4B-4bit")
    ///   - coordinatorURL: The coordinator endpoint URL
    ///   - port: The local port for the MLX backend
    func start(model: String, coordinatorURL: String, port: Int) {
        guard !isRunning else { return }

        currentModel = model
        currentCoordinatorURL = coordinatorURL
        currentPort = port
        autoRestartEnabled = true
        restartCount = 0

        spawnProcess()
    }

    /// Stop the provider subprocess.
    ///
    /// Sends SIGTERM first, waits up to 5 seconds for clean shutdown,
    /// then sends SIGKILL if the process hasn't exited. Disables
    /// auto-restart so the process stays down.
    func stop() {
        autoRestartEnabled = false

        guard let process = process, process.isRunning else {
            isRunning = false
            return
        }

        // SIGTERM for graceful shutdown
        process.terminate()

        // Wait up to 5 seconds, then SIGKILL
        DispatchQueue.global().async { [weak self] in
            for _ in 0..<50 {
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.1)
            }

            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }

            Task { @MainActor in
                self?.isRunning = false
                self?.process = nil
            }
        }
    }

    // MARK: - Internal

    /// Spawn the provider process and wire up output capture.
    private func spawnProcess() {
        guard let binaryPath = Self.resolveBinaryPath() else {
            lastError = "eigeninference-provider binary not found. Run the installer:\n"
                + "  curl -fsSL https://inference-test.openinnovation.dev/install.sh | bash"
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = Self.buildArguments(
            model: currentModel,
            coordinatorURL: currentCoordinatorURL,
            port: currentPort
        )

        // Match CLIRunner's environment so the provider subprocess can find
        // Python/vllm-mlx and other tools in the same paths the CLI uses.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var env = ProcessInfo.processInfo.environment
        let extraPaths = [
            "\(home)/.eigeninference/bin",
            "\(home)/.eigeninference/python/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        let existingPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")

        let pythonHome = "\(home)/.eigeninference/python"
        if FileManager.default.fileExists(atPath: "\(pythonHome)/bin/python3.12") {
            env["PYTHONHOME"] = pythonHome
        }
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Read stdout line by line
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let line = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else { return }

            Task { @MainActor in
                self?.lastOutputLine = line
            }
        }

        // Read stderr
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let line = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty else { return }

            Task { @MainActor in
                self?.lastError = line
            }
        }

        // Handle process termination
        proc.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor in
                guard let self = self else { return }
                self.isRunning = false
                self.process = nil

                // Auto-restart on crash (non-zero exit)
                if self.autoRestartEnabled
                    && terminatedProcess.terminationStatus != 0
                    && self.restartCount < self.maxRestarts
                {
                    self.restartCount += 1
                    // Exponential backoff: 1s, 2s, 4s, 8s, 16s
                    let delay = pow(2.0, Double(self.restartCount - 1))
                    try? await Task.sleep(for: .seconds(delay))
                    if self.autoRestartEnabled {
                        self.spawnProcess()
                    }
                } else if self.autoRestartEnabled
                    && terminatedProcess.terminationStatus != 0
                    && self.restartCount >= self.maxRestarts
                {
                    self.autoRestartEnabled = false
                    let content = UNMutableNotificationContent()
                    content.title = "EigenInference Provider Stopped"
                    content.body = "Provider crashed \(self.maxRestarts) times. Check logs: eigeninference-provider logs"
                    content.sound = .default
                    let request = UNNotificationRequest(identifier: "crash-limit", content: content, trigger: nil)
                    try? await UNUserNotificationCenter.current().add(request)
                }
            }
        }

        do {
            try proc.run()
            process = proc
            stdoutPipe = outPipe
            stderrPipe = errPipe
            isRunning = true
        } catch {
            lastError = "Failed to start provider: \(error.localizedDescription)"
            isRunning = false
        }
    }
}
