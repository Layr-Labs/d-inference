/// StatusViewModel — Observable state for the Darkbloom menu bar UI.
///
/// Centralizes all provider state: online/serving status, hardware info,
/// throughput metrics, session stats, security posture, wallet/earnings.
///
/// State flow:
///   ProviderManager stdout → StatusViewModel properties → SwiftUI views
///   IdleDetector events → StatusViewModel.pause()/resume() → ProviderManager
///   SecurityManager → trust/security display
///   CLIRunner → wallet, earnings, coordinator connectivity

import Combine
import Foundation
import Security
import SwiftUI

@MainActor
final class StatusViewModel: ObservableObject {

    // MARK: - Provider State

    @Published var isOnline = false
    @Published var isServing = false
    @Published var isPaused = false
    @Published var currentModel = "None"
    @Published var tokensPerSecond: Double = 0
    @Published var requestsServed = 0
    @Published var tokensGenerated = 0
    @Published var uptimeSeconds = 0

    // MARK: - Hardware Info

    @Published var chipName = "Detecting..."
    @Published var memoryGB = 0
    @Published var gpuCores = 0
    @Published var memoryBandwidthGBs = 0

    // MARK: - Wallet & Earnings

    @Published var walletAddress = ""
    @Published var earningsBalance = ""

    // MARK: - Connectivity

    @Published var coordinatorConnected = false

    // MARK: - Setup

    @Published var hasCompletedSetup: Bool {
        didSet { UserDefaults.standard.set(hasCompletedSetup, forKey: "hasCompletedSetup") }
    }

    // MARK: - Settings (persisted via provider.toml — shared with CLI)

    @Published var coordinatorURL: String {
        didSet {
            try? ConfigManager.update { $0.coordinatorURL = coordinatorURL }
        }
    }

    @Published var apiKey: String {
        didSet { saveKeychainItem(key: "apiKey", value: apiKey) }
    }

    @Published var autoStart: Bool {
        didSet {
            UserDefaults.standard.set(autoStart, forKey: "autoStart")
            LaunchAgentManager.sync(autoStart: autoStart)
        }
    }

    @Published var idleTimeoutSeconds: TimeInterval {
        didSet {
            UserDefaults.standard.set(idleTimeoutSeconds, forKey: "idleTimeoutSeconds")
            idleDetector.idleTimeoutSeconds = idleTimeoutSeconds
        }
    }

    // MARK: - Schedule Settings (persisted via UserDefaults, synced to provider config)

    @Published var scheduleEnabled: Bool {
        didSet {
            UserDefaults.standard.set(scheduleEnabled, forKey: "scheduleEnabled")
            syncScheduleToConfig()
        }
    }

    @Published var scheduleWindows: [ScheduleWindowModel] {
        didSet {
            if let data = try? JSONEncoder().encode(scheduleWindows) {
                UserDefaults.standard.set(data, forKey: "scheduleWindows")
            }
            syncScheduleToConfig()
        }
    }

    // MARK: - Managers

    let providerManager = ProviderManager()
    let idleDetector = IdleDetector()
    let modelManager = ModelManager()
    let securityManager = SecurityManager()
    let notificationManager = NotificationManager()
    let updateManager = UpdateManager()

    private var uptimeTimer: Timer?
    private var earningsTimer: Timer?
    private var connectivityTimer: Timer?
    private var caffeinateProcess: Process?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init() {
        // Load from provider.toml (shared with CLI) — single source of truth
        let config = ConfigManager.load()
        self.coordinatorURL = config.coordinatorURL
        self.currentModel = config.backendModel ?? "None"

        self.apiKey = Self.loadKeychainItem(key: "apiKey") ?? ""
        self.autoStart = UserDefaults.standard.bool(forKey: "autoStart")
        self.idleTimeoutSeconds = UserDefaults.standard.double(forKey: "idleTimeoutSeconds")
        self.hasCompletedSetup = UserDefaults.standard.bool(forKey: "hasCompletedSetup")
        self.scheduleEnabled = UserDefaults.standard.bool(forKey: "scheduleEnabled")
        if let data = UserDefaults.standard.data(forKey: "scheduleWindows"),
           let windows = try? JSONDecoder().decode([ScheduleWindowModel].self, from: data) {
            self.scheduleWindows = windows
        } else {
            self.scheduleWindows = [ScheduleWindowModel.defaultWindow()]
        }

        if idleTimeoutSeconds == 0 {
            idleTimeoutSeconds = 300
        }
        idleDetector.idleTimeoutSeconds = idleTimeoutSeconds

        detectHardware()
        notificationManager.requestAuthorization()

        // Scan for downloaded models
        modelManager.scanModels()

        // Poll real provider status every 5 seconds
        startStatusPoller()

        // Periodic background tasks
        startPeriodicTasks()

        // Initial security check
        Task {
            await securityManager.refresh()
            await refreshWallet()
        }
    }

    // MARK: - Actions

    func start() {
        guard !isOnline else { return }

        Task {
            do {
                let result = try await CLIRunner.run(["start", "--model", currentModel])
                if result.success {
                    notificationManager.notifyProviderOnline(model: currentModel)
                }
            } catch {}
            await pollProviderStatus()
        }
    }

    func stop() {
        Task {
            do {
                let _ = try await CLIRunner.run(["stop"])
            } catch {}
            isOnline = false
            isServing = false
            isPaused = false
            tokensPerSecond = 0
            uptimeTimer?.invalidate()
            uptimeTimer = nil
            notificationManager.notifyProviderOffline()
        }
    }

    /// Pause the provider — stops the process (clean restart on resume).
    func pauseProvider() {
        isPaused = true
        stop()
    }

    /// Resume the provider — restart the process.
    func resumeProvider() {
        isPaused = false
        start()
    }

    // MARK: - Real System State Polling

    private var statusPoller: Timer?

    private func startStatusPoller() {
        // Initial poll
        Task { await pollProviderStatus() }

        // Poll every 5 seconds
        statusPoller = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.pollProviderStatus()
            }
        }
    }

    /// Check real system state: is darkbloom running? Is the backend healthy?
    func pollProviderStatus() async {
        // Check if a darkbloom serve process is running
        let processRunning = Self.isProviderProcessRunning()

        // Check if the backend is healthy on port 8100
        var backendHealthy = false
        var backendModel = "None"
        var engineType = ""

        if processRunning {
            if let url = URL(string: "http://127.0.0.1:8100/health") {
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    if (response as? HTTPURLResponse)?.statusCode == 200 {
                        backendHealthy = true
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            if let name = json["model_name"] as? String {
                                let parts = name.components(separatedBy: "/")
                                backendModel = parts.last ?? name
                            }
                            engineType = json["engine_type"] as? String ?? ""
                        }
                    }
                } catch {}
            }
        }

        let wasOnline = isOnline
        isOnline = processRunning && backendHealthy

        if isOnline && !wasOnline {
            uptimeSeconds = 0
            uptimeTimer?.invalidate()
            uptimeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.uptimeSeconds += 1 }
            }
        } else if !isOnline && wasOnline {
            uptimeTimer?.invalidate()
            uptimeTimer = nil
            isServing = false
            tokensPerSecond = 0
        }

        if backendHealthy {
            currentModel = backendModel
            coordinatorConnected = true
        }
    }

    /// Check if a darkbloom serve process is running via pgrep.
    private static func isProviderProcessRunning() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-f", "darkbloom serve"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    // MARK: - Wallet & Earnings

    func refreshWallet() async {
        do {
            let result = try await CLIRunner.run(["wallet"])
            if result.success {
                // Parse "Address: 0x..." from output
                for line in result.output.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.lowercased().hasPrefix("address:") {
                        walletAddress = trimmed.components(separatedBy: ":").last?
                            .trimmingCharacters(in: .whitespaces) ?? ""
                        break
                    }
                    // Also match "0x..." directly
                    if trimmed.hasPrefix("0x") && trimmed.count >= 40 {
                        walletAddress = trimmed
                        break
                    }
                }
            }
        } catch {}
    }

    func refreshEarnings() async {
        let baseURL = coordinatorURL
            .replacingOccurrences(of: "ws://", with: "http://")
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "/ws/provider", with: "")

        do {
            let result = try await CLIRunner.run(["earnings", "--coordinator", baseURL])
            if result.success {
                for line in result.output.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.lowercased().contains("balance") || trimmed.contains("$") {
                        earningsBalance = trimmed.components(separatedBy: ":").last?
                            .trimmingCharacters(in: .whitespaces) ?? trimmed
                        break
                    }
                }
            }
        } catch {}
    }

    // MARK: - Connectivity

    func checkCoordinatorConnectivity() async {
        let baseURL = coordinatorURL
            .replacingOccurrences(of: "ws://", with: "http://")
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "/ws/provider", with: "")

        guard let url = URL(string: "\(baseURL)/health") else {
            coordinatorConnected = false
            return
        }

        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            coordinatorConnected = (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            coordinatorConnected = false
        }
    }

    // MARK: - Hardware Detection

    private func detectHardware() {
        var memSize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memSize, &size, nil, 0)
        memoryGB = Int(memSize / (1024 * 1024 * 1024))

        Task { [weak self] in
            let (chip, cores, bandwidth) = await Self.getHardwareInfo()
            await MainActor.run {
                self?.chipName = chip
                self?.gpuCores = cores
                self?.memoryBandwidthGBs = bandwidth
            }
        }
    }

    private static func getHardwareInfo() async -> (String, Int, Int) {
        var chipName = "Unknown"
        var gpuCores = 0
        var bandwidth = 0

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

        // Bandwidth estimates by chip
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

    /// Parse tracing-formatted output from the provider binary.
    ///
    /// The Rust binary uses `tracing` which outputs lines like:
    ///   2026-03-24T10:00:00.123Z  INFO darkbloom: Connected to coordinator
    ///   2026-03-24T10:00:01.234Z  INFO darkbloom: Received inference request: req-abc
    private func parseProviderOutput(_ line: String) {
        guard !line.isEmpty else { return }
        let lower = line.lowercased()

        // Connection status
        if lower.contains("connected to coordinator") || lower.contains("registered with coordinator") {
            isOnline = true
        } else if lower.contains("disconnected") || lower.contains("connection error") ||
                  lower.contains("connection closed") {
            isOnline = false
            isServing = false
        }

        // Inference lifecycle
        if lower.contains("received inference request") || lower.contains("handling inference") {
            isServing = true
        } else if lower.contains("inferencecomplete") || lower.contains("inference complete") ||
                  lower.contains("request completed") {
            isServing = false
            requestsServed += 1
            notificationManager.notifyInferenceCompleted(requestCount: requestsServed)
        } else if lower.contains("inference error") || lower.contains("inferenceerror") {
            isServing = false
        }

        // Throughput parsing — look for "tok/s" or "tokens/s" or "tps"
        if let range = line.range(of: #"(\d+\.?\d*)\s*(tok/s|tokens/s|tps)"#, options: .regularExpression) {
            let match = String(line[range])
            let numStr = match.components(separatedBy: CharacterSet.decimalDigits.inverted.subtracting(CharacterSet(charactersIn: ".")))
                .joined()
            if let tps = Double(numStr) {
                tokensPerSecond = tps
            }
        }

        // Token count from completion messages
        if lower.contains("tokens=") || lower.contains("completion_tokens") {
            if let range = line.range(of: #"tokens[=:]\s*(\d+)"#, options: .regularExpression) {
                let match = String(line[range])
                let numStr = match.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                if let count = Int(numStr), count > 0 {
                    tokensGenerated += count
                    notificationManager.notifyTokenMilestone(tokensGenerated)
                }
            }
        }

        // Legacy format support
        if line.contains("[STATUS] online") { isOnline = true }
        if line.contains("[STATUS] offline") { isOnline = false }
        if line.contains("[SERVING]") { isServing = true }
        if line.contains("[DONE]") { isServing = false; requestsServed += 1 }
    }

    // MARK: - Periodic Tasks

    private func startPeriodicTasks() {
        // Earnings refresh every 5 minutes
        earningsTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshEarnings()
            }
        }

        // Coordinator connectivity check every 30 seconds
        connectivityTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkCoordinatorConnectivity()
            }
        }

        // Initial connectivity check
        Task {
            await checkCoordinatorConnectivity()
            await updateManager.checkForUpdates(coordinatorURL: coordinatorURL)
        }
    }

    // MARK: - Keychain

    private static func loadKeychainItem(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.darkbloom.provider",
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func saveKeychainItem(key: String, value: String) {
        let data = value.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.darkbloom.provider",
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    // MARK: - Schedule Config Sync

    /// Write schedule settings to the provider TOML config so the CLI respects them.
    func syncScheduleToConfig() {
        guard let configDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .deletingLastPathComponent()
            .appendingPathComponent(".config/darkbloom") else { return }

        let configPath = configDir.appendingPathComponent("provider.toml")

        // Read existing config (if any)
        var tomlContent = (try? String(contentsOf: configPath, encoding: .utf8)) ?? ""

        // Remove existing [schedule] section (everything from [schedule] to next section or EOF)
        if let range = tomlContent.range(of: #"\[schedule\][\s\S]*?(?=\n\[|$)"#, options: .regularExpression) {
            tomlContent.removeSubrange(range)
        }

        // Build schedule TOML
        var scheduleToml = "\n[schedule]\nenabled = \(scheduleEnabled)\n"

        for window in scheduleWindows {
            let days = window.activeDays.map { "\"\($0)\"" }.joined(separator: ", ")
            scheduleToml += "\n[[schedule.windows]]\ndays = [\(days)]\nstart = \"\(window.startTime)\"\nend = \"\(window.endTime)\"\n"
        }

        tomlContent = tomlContent.trimmingCharacters(in: .whitespacesAndNewlines)
        tomlContent += scheduleToml

        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? tomlContent.write(to: configPath, atomically: true, encoding: .utf8)
    }
}

// MARK: - Schedule Window Model

/// A single time window for provider availability scheduling.
struct ScheduleWindowModel: Identifiable, Codable, Equatable {
    let id: UUID
    var activeDays: [String]   // e.g., ["mon", "tue", "wed"]
    var startTime: String      // "HH:MM" 24h format
    var endTime: String        // "HH:MM" 24h format

    static let allDays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    static let dayLabels: [String: String] = [
        "mon": "Mon", "tue": "Tue", "wed": "Wed", "thu": "Thu",
        "fri": "Fri", "sat": "Sat", "sun": "Sun"
    ]

    static func defaultWindow() -> ScheduleWindowModel {
        ScheduleWindowModel(
            id: UUID(),
            activeDays: ["mon", "tue", "wed", "thu", "fri", "sat", "sun"],
            startTime: "22:00",
            endTime: "08:00"
        )
    }

    var isOvernight: Bool {
        guard let start = timeMinutes(startTime), let end = timeMinutes(endTime) else { return false }
        return end <= start
    }

    var description: String {
        let dayStr = activeDays.compactMap { Self.dayLabels[$0] }.joined(separator: ", ")
        let overnight = isOvernight ? " (overnight)" : ""
        return "\(dayStr): \(startTime)–\(endTime)\(overnight)"
    }

    private func timeMinutes(_ s: String) -> Int? {
        let parts = s.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }
}
