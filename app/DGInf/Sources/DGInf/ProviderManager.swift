/// ProviderManager — Manages the Rust provider binary as a subprocess.
///
/// This class wraps Foundation's `Process` to spawn, monitor, and stop the
/// `dginf-provider` binary. It captures stdout/stderr for status parsing,
/// auto-restarts on unexpected crashes, and resolves the binary path from
/// multiple candidate locations.
///
/// Binary path resolution order:
///   1. Same directory as the running app bundle
///   2. `~/.dginf/bin/dginf-provider`
///   3. Standard PATH lookup via `/usr/bin/env which`
///
/// The provider binary is invoked as:
///   dginf-provider serve --coordinator <url> --model <model> --backend-port <port>

import Combine
import Foundation
import UserNotifications

/// Manages the dginf-provider subprocess lifecycle.
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

    /// Resolve the path to the dginf-provider binary.
    ///
    /// Searches in order:
    ///   1. Adjacent to the app bundle (for production distribution)
    ///   2. `~/.dginf/bin/dginf-provider` (for manual installs)
    ///   3. PATH lookup (for development)
    ///
    /// Returns nil if the binary cannot be found anywhere.
    nonisolated static func resolveBinaryPath() -> String? {
        // 1. Adjacent to app bundle
        if let bundlePath = Bundle.main.executablePath {
            let bundleDir = (bundlePath as NSString).deletingLastPathComponent
            let adjacent = (bundleDir as NSString).appendingPathComponent("dginf-provider")
            if FileManager.default.isExecutableFile(atPath: adjacent) {
                return adjacent
            }
        }

        // 2. ~/.dginf/bin/dginf-provider
        let home = FileManager.default.homeDirectoryForCurrentUser
        let homeBin = home.appendingPathComponent(".dginf/bin/dginf-provider").path
        if FileManager.default.isExecutableFile(atPath: homeBin) {
            return homeBin
        }

        // 3. PATH lookup
        let whichProcess = Process()
        let whichPipe = Pipe()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["dginf-provider"]
        whichProcess.standardOutput = whichPipe
        whichProcess.standardError = Pipe()
        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
            if whichProcess.terminationStatus == 0 {
                let data = whichPipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let path = path, !path.isEmpty {
                    return path
                }
            }
        } catch {
            // which failed, binary not in PATH
        }

        return nil
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
            lastError = "dginf-provider binary not found. Searched:\n"
                + "  - Adjacent to app bundle\n"
                + "  - ~/.dginf/bin/dginf-provider\n"
                + "  - PATH"
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = Self.buildArguments(
            model: currentModel,
            coordinatorURL: currentCoordinatorURL,
            port: currentPort
        )

        // Set up pipes for output capture
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
                    content.title = "DGInf Provider Stopped"
                    content.body = "Provider crashed \(self.maxRestarts) times. Check logs: dginf-provider logs"
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
