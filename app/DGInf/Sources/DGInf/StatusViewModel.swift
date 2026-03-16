/// StatusViewModel — Observable state for the DGInf menu bar UI.
///
/// This view model centralizes all provider state that the UI needs to display:
/// online/serving status, hardware info, throughput metrics, and session stats.
/// It bridges between the ProviderManager (subprocess control), IdleDetector
/// (user activity monitoring), and the SwiftUI views.
///
/// State flow:
///   ProviderManager stdout → StatusViewModel properties → SwiftUI views
///   IdleDetector events → StatusViewModel.pause()/resume() → ProviderManager
///
/// All published properties are updated on the main actor to ensure
/// thread-safe UI updates.

import Combine
import Foundation
import SwiftUI

/// Centralizes provider state for the menu bar UI.
///
/// Published properties drive SwiftUI updates. The view model owns both
/// the ProviderManager (subprocess lifecycle) and IdleDetector (user
/// activity monitoring), coordinating between them.
@MainActor
final class StatusViewModel: ObservableObject {

    // MARK: - Provider State

    /// Whether the provider is connected to the coordinator and accepting work.
    @Published var isOnline = false

    /// Whether the provider is actively serving an inference request right now.
    @Published var isServing = false

    /// Whether the provider is paused because the user is active at the keyboard.
    @Published var isPaused = false

    /// The model currently loaded for inference (e.g., "mlx-community/Qwen3.5-4B-4bit").
    @Published var currentModel = "None"

    /// Current inference throughput in tokens per second.
    @Published var tokensPerSecond: Double = 0

    /// Total inference requests served in this session.
    @Published var requestsServed = 0

    /// Total tokens generated in this session.
    @Published var tokensGenerated = 0

    /// Seconds since the provider was started.
    @Published var uptimeSeconds = 0

    // MARK: - Hardware Info

    /// The Apple Silicon chip name (e.g., "Apple M3 Max").
    @Published var chipName = "Detecting..."

    /// Total unified memory in gigabytes.
    @Published var memoryGB = 0

    /// Number of GPU cores.
    @Published var gpuCores = 0

    /// Memory bandwidth in GB/s (estimated from chip).
    @Published var memoryBandwidthGBs = 0

    // MARK: - Settings (persisted via UserDefaults)

    /// The coordinator URL the provider connects to.
    @Published var coordinatorURL: String {
        didSet { UserDefaults.standard.set(coordinatorURL, forKey: "coordinatorURL") }
    }

    /// API key for authenticating with the coordinator.
    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: "apiKey") }
    }

    /// Whether to start the provider automatically on login.
    @Published var autoStart: Bool {
        didSet { UserDefaults.standard.set(autoStart, forKey: "autoStart") }
    }

    /// Idle timeout in seconds before the provider resumes serving.
    @Published var idleTimeoutSeconds: TimeInterval {
        didSet {
            UserDefaults.standard.set(idleTimeoutSeconds, forKey: "idleTimeoutSeconds")
            idleDetector.idleTimeoutSeconds = idleTimeoutSeconds
        }
    }

    // MARK: - Internal

    let providerManager = ProviderManager()
    let idleDetector = IdleDetector()
    let modelManager = ModelManager()
    private var uptimeTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init() {
        // Load persisted settings with defaults
        self.coordinatorURL = UserDefaults.standard.string(forKey: "coordinatorURL")
            ?? "https://coordinator.dginf.io"
        self.apiKey = UserDefaults.standard.string(forKey: "apiKey") ?? ""
        self.autoStart = UserDefaults.standard.bool(forKey: "autoStart")
        self.idleTimeoutSeconds = UserDefaults.standard.double(forKey: "idleTimeoutSeconds")

        // Default idle timeout to 5 minutes if not set
        if idleTimeoutSeconds == 0 {
            idleTimeoutSeconds = 300
        }
        idleDetector.idleTimeoutSeconds = idleTimeoutSeconds

        // Detect hardware on init
        detectHardware()

        // Observe idle state changes
        idleDetector.$isUserIdle
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isIdle in
                guard let self = self else { return }
                if isIdle && self.isPaused {
                    self.resumeProvider()
                } else if !isIdle && self.isOnline && !self.isPaused {
                    self.pauseProvider()
                }
            }
            .store(in: &cancellables)

        // Observe provider output for status updates
        providerManager.$lastOutputLine
            .receive(on: DispatchQueue.main)
            .sink { [weak self] line in
                self?.parseProviderOutput(line)
            }
            .store(in: &cancellables)

        providerManager.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                guard let self = self else { return }
                if !running {
                    self.isOnline = false
                    self.isServing = false
                    self.tokensPerSecond = 0
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    /// Start the provider subprocess and begin serving.
    func start() {
        guard !providerManager.isRunning else { return }

        providerManager.start(
            model: currentModel,
            coordinatorURL: coordinatorURL,
            port: 8321
        )
        isOnline = true
        isPaused = false
        uptimeSeconds = 0

        // Start uptime counter
        uptimeTimer?.invalidate()
        uptimeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.uptimeSeconds += 1
            }
        }

        // Start monitoring user activity
        idleDetector.start()
    }

    /// Stop the provider subprocess.
    func stop() {
        providerManager.stop()
        idleDetector.stop()
        uptimeTimer?.invalidate()
        uptimeTimer = nil
        isOnline = false
        isServing = false
        isPaused = false
        tokensPerSecond = 0
    }

    /// Pause the provider (user became active).
    func pauseProvider() {
        isPaused = true
        // The provider finishes its current job but stops accepting new ones.
        // In the real implementation, this would send a signal/API call to the
        // provider binary. For now we track the state.
    }

    /// Resume the provider (user went idle).
    func resumeProvider() {
        isPaused = false
    }

    // MARK: - Hardware Detection

    /// Detect the local hardware: chip name, memory, GPU cores.
    ///
    /// Uses sysctl for memory and system_profiler for chip name.
    /// This runs once at init time.
    private func detectHardware() {
        // Memory via sysctl
        var memSize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memSize, &size, nil, 0)
        memoryGB = Int(memSize / (1024 * 1024 * 1024))

        // GPU cores via sysctl (Apple Silicon reports this via hw.perflevel0.logicalcpu on some versions)
        var gpuCount: Int32 = 0
        var gpuSize = MemoryLayout<Int32>.size
        // Metal GPU core count isn't directly available via sysctl, use a reasonable approach
        if sysctlbyname("hw.logicalcpu", &gpuCount, &gpuSize, nil, 0) == 0 {
            // This gives CPU cores, not GPU cores. We'll parse system_profiler for GPU.
        }

        // Chip name and GPU cores from system_profiler (async to avoid blocking init)
        Task { [weak self] in
            let (chip, cores, bandwidth) = await Self.getHardwareInfo()
            await MainActor.run {
                self?.chipName = chip
                self?.gpuCores = cores
                self?.memoryBandwidthGBs = bandwidth
            }
        }
    }

    /// Parse system_profiler output for chip name and GPU core count.
    ///
    /// Runs system_profiler SPHardwareDataType and SPDisplaysDataType.
    /// Returns (chipName, gpuCores, bandwidthGBs).
    private static func getHardwareInfo() async -> (String, Int, Int) {
        var chipName = "Unknown"
        var gpuCores = 0
        var bandwidth = 0

        // Get chip name
        let hardwarePipe = Pipe()
        let hardwareProcess = Process()
        hardwareProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        hardwareProcess.arguments = ["SPHardwareDataType"]
        hardwareProcess.standardOutput = hardwarePipe
        hardwareProcess.standardError = Pipe()
        try? hardwareProcess.run()
        hardwareProcess.waitUntilExit()

        let hardwareData = hardwarePipe.fileHandleForReading.readDataToEndOfFile()
        let hardwareOutput = String(data: hardwareData, encoding: .utf8) ?? ""

        for line in hardwareOutput.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Chip:") {
                chipName = trimmed.components(separatedBy: ":").last?
                    .trimmingCharacters(in: .whitespaces) ?? "Unknown"
            }
            if trimmed.contains("Total Number of Cores") && trimmed.contains("GPU") {
                // e.g., "Total Number of Cores: 40 (12 performance and 4 efficiency and 24 GPU)"
                // or a separate GPU line
                let parts = trimmed.components(separatedBy: " ")
                for (i, part) in parts.enumerated() {
                    if part == "GPU" || part == "GPU)" {
                        if i > 0, let count = Int(parts[i - 1].replacingOccurrences(of: "(", with: "")) {
                            gpuCores = count
                        }
                    }
                }
            }
        }

        // Estimate bandwidth from chip name (rough values)
        if chipName.contains("M4 Max") { bandwidth = 546 }
        else if chipName.contains("M4 Pro") { bandwidth = 273 }
        else if chipName.contains("M4") { bandwidth = 120 }
        else if chipName.contains("M3 Max") { bandwidth = 400 }
        else if chipName.contains("M3 Pro") { bandwidth = 150 }
        else if chipName.contains("M3") { bandwidth = 100 }
        else if chipName.contains("M2 Ultra") { bandwidth = 800 }
        else if chipName.contains("M2 Max") { bandwidth = 400 }
        else if chipName.contains("M2 Pro") { bandwidth = 200 }
        else if chipName.contains("M2") { bandwidth = 100 }
        else if chipName.contains("M1 Ultra") { bandwidth = 800 }
        else if chipName.contains("M1 Max") { bandwidth = 400 }
        else if chipName.contains("M1 Pro") { bandwidth = 200 }
        else if chipName.contains("M1") { bandwidth = 68 }

        // Get GPU cores from displays data if not found above
        if gpuCores == 0 {
            let displayPipe = Pipe()
            let displayProcess = Process()
            displayProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            displayProcess.arguments = ["SPDisplaysDataType"]
            displayProcess.standardOutput = displayPipe
            displayProcess.standardError = Pipe()
            try? displayProcess.run()
            displayProcess.waitUntilExit()

            let displayData = displayPipe.fileHandleForReading.readDataToEndOfFile()
            let displayOutput = String(data: displayData, encoding: .utf8) ?? ""

            for line in displayOutput.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.contains("Total Number of Cores:") {
                    let parts = trimmed.components(separatedBy: ":")
                    if let countStr = parts.last?.trimmingCharacters(in: .whitespaces),
                       let count = Int(countStr) {
                        gpuCores = count
                    }
                }
            }
        }

        return (chipName, gpuCores, bandwidth)
    }

    // MARK: - Provider Output Parsing

    /// Parse a line of stdout from the provider binary to update state.
    ///
    /// The provider binary outputs structured status lines that we parse
    /// to update the UI. Expected formats:
    ///   - `[STATUS] online` / `[STATUS] offline`
    ///   - `[SERVING] model=... tokens/s=...`
    ///   - `[DONE] requests=... tokens=...`
    private func parseProviderOutput(_ line: String) {
        guard !line.isEmpty else { return }

        if line.contains("[STATUS] online") {
            isOnline = true
        } else if line.contains("[STATUS] offline") {
            isOnline = false
        } else if line.contains("[SERVING]") {
            isServing = true
            // Parse tokens/s if present
            if let range = line.range(of: "tokens/s=") {
                let rest = line[range.upperBound...]
                if let spaceIdx = rest.firstIndex(of: " ") {
                    if let tps = Double(rest[rest.startIndex..<spaceIdx]) {
                        tokensPerSecond = tps
                    }
                } else if let tps = Double(rest) {
                    tokensPerSecond = tps
                }
            }
        } else if line.contains("[DONE]") {
            isServing = false
            requestsServed += 1
            // Parse tokens generated
            if let range = line.range(of: "tokens=") {
                let rest = line[range.upperBound...]
                if let spaceIdx = rest.firstIndex(of: " ") {
                    if let count = Int(rest[rest.startIndex..<spaceIdx]) {
                        tokensGenerated += count
                    }
                } else if let count = Int(rest) {
                    tokensGenerated += count
                }
            }
        }
    }
}
