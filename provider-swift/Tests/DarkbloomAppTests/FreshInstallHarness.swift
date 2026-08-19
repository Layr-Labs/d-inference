import Foundation
import ProviderCoreFoundation
@testable import DarkbloomApp

/// Hermetic machine boundary for download-app-first onboarding tests.
///
/// Every persistent artifact lives below `root`: preferences, CLI controls,
/// downloaded-model markers, daemon state, local discovery, and configuration.
/// The executable is selected through the production `DARKBLOOM_CLI_PATH`
/// locator contract and rejects every argv shape onboarding is not expected to
/// use. It never invokes the real CLI, coordinator, profiles tool, launchd,
/// keychain, Terminal, or System Settings.
struct FreshInstallHarness: Sendable {
    static let modelID = "mlx-community/Qwen3.5-0.8B-MLX-4bit"

    let root: URL
    let home: URL
    let stateFile: URL
    let localDirectory: URL
    let configDirectory: URL
    let preferencesFile: URL
    let executable: URL

    private let controlDirectory: URL
    private let machineDirectory: URL
    private let invocationFile: URL

    init(testName: String = #function) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "darkbloom-fresh-install-\(Self.safeName(testName))-\(UUID().uuidString)",
                isDirectory: true
            )
        home = root.appendingPathComponent("home", isDirectory: true)
        stateFile = root.appendingPathComponent("state/daemon-state.json")
        localDirectory = root.appendingPathComponent("local", isDirectory: true)
        configDirectory = root.appendingPathComponent("config", isDirectory: true)
        preferencesFile = root.appendingPathComponent("preferences/app-flow.json")
        executable = root.appendingPathComponent("darkbloom")
        controlDirectory = root.appendingPathComponent("control", isDirectory: true)
        machineDirectory = root.appendingPathComponent("machine", isDirectory: true)
        invocationFile = root.appendingPathComponent("argv.log")

        for directory in [
            home,
            stateFile.deletingLastPathComponent(),
            localDirectory,
            configDirectory,
            preferencesFile.deletingLastPathComponent(),
            controlDirectory,
            machineDirectory,
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        try FreshInstallFakeCLI.script.write(
            to: executable,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        precondition(!FileManager.default.fileExists(atPath: preferencesFile.path))
        precondition(!FileManager.default.fileExists(atPath: stateFile.path))
        precondition(!FileManager.default.fileExists(
            atPath: localDirectory.appendingPathComponent("local.json").path
        ))
        precondition(root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Uses production environment-key precedence without mutating the test
    /// process environment, which would race unrelated suites.
    func locator() -> SystemDarkbloomCLILocator {
        SystemDarkbloomCLILocator(
            environment: [SystemDarkbloomCLILocator.environmentKey: executable.path],
            bundleURL: root.appendingPathComponent("Empty.app")
        )
    }

    @MainActor
    func preferences() -> FreshInstallPreferences {
        FreshInstallPreferences(fileURL: preferencesFile)
    }

    func diagnosticsRunner() -> ProcessDiagnosticsCLIRunner {
        ProcessDiagnosticsCLIRunner(locator: locator())
    }

    func accountRunner() -> ProcessAccountLinkCLI {
        ProcessAccountLinkCLI(locator: locator())
    }

    func modelRunner(memoryGB: UInt64 = 32) -> ProcessModelCatalogCLIRunner {
        ProcessModelCatalogCLIRunner(
            locator: locator(),
            stateFileURL: stateFile,
            physicalMemoryBytes: memoryGB * 1_073_741_824
        )
    }

    func providerRunner() -> ProcessProviderCLIRunner {
        ProcessProviderCLIRunner(locator: locator())
    }

    func localEndpoint() -> LocalEndpointInfo? {
        let url = localDirectory.appendingPathComponent("local.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LocalEndpointInfo.self, from: data)
    }

    func providerEvidence() -> OnboardingProviderEvidence {
        OnboardingProviderEvidence(
            daemonState: DaemonStateFile.read(from: stateFile),
            localEndpoint: localEndpoint()
        )
    }

    @MainActor
    func makeFlow(
        startingAt step: OnboardingStep = .readiness,
        readinessFacts: ReadinessMachineFacts = .freshInstallFixture,
        openedURLs: FreshInstallURLRecorder = FreshInstallURLRecorder(),
        enrollmentPollInterval: Duration = .seconds(60),
        verificationPollInterval: Duration = .milliseconds(10),
        verificationCheckInGrace: Duration = .milliseconds(100)
    ) -> OnboardingFlowModel {
        let preparation = OnboardingPreparationService(
            catalog: modelRunner(),
            startCLI: ProcessSetupStartCLI(runner: providerRunner(), timeout: .seconds(2)),
            availableStorageBytes: { 20 * 1_073_741_824 }
        )
        return OnboardingFlowModel(
            startingAt: step,
            diagnosticsRunner: diagnosticsRunner(),
            readinessFactsProvider: { readinessFacts },
            accountLinkRunner: accountRunner(),
            enrollmentRunner: ProcessEnrollmentCLI(locator: locator()),
            preparationService: preparation,
            verificationURLHandler: { openedURLs.append($0) },
            daemonStateProvider: { DaemonStateFile.read(from: stateFile) },
            providerEvidenceProvider: { providerEvidence() },
            enrollmentPollInterval: enrollmentPollInterval,
            verificationPollInterval: verificationPollInterval,
            verificationCheckInGrace: verificationCheckInGrace
        )
    }

    func setMode(_ mode: String, for contract: Contract) throws {
        try Data((mode + "\n").utf8).write(
            to: controlDirectory.appendingPathComponent(contract.rawValue),
            options: .atomic
        )
    }

    func clearMode(for contract: Contract) throws {
        let file = controlDirectory.appendingPathComponent(contract.rawValue)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    func markAccountLinked() throws {
        try markMachineTruth("account-linked")
    }

    func markProfileInstalled() throws {
        try markMachineTruth("profile-installed")
    }

    func markModelDownloaded() throws {
        try markMachineTruth("model-downloaded")
    }

    func markProviderStarted(trust: DaemonState.Trust? = Self.pendingTrust) throws {
        try writeDaemonState(trust: trust)
        try writeLocalEndpoint()
    }

    func setTrust(status: String, level: String, reason: String = "") throws {
        try writeDaemonState(trust: DaemonState.Trust(
            trustLevel: level,
            status: status,
            reason: reason,
            receivedAt: Date().timeIntervalSince1970
        ))
        try writeLocalEndpoint()
    }

    func invocations() throws -> [[String]] {
        guard FileManager.default.fileExists(atPath: invocationFile.path) else { return [] }
        let text = try String(contentsOf: invocationFile, encoding: .utf8)
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                line.split(separator: "\u{1c}", omittingEmptySubsequences: false).map(String.init)
            }
    }

    func assertHermeticPaths() -> Bool {
        let paths = [
            home,
            stateFile,
            localDirectory,
            configDirectory,
            preferencesFile,
            executable,
        ]
        return paths.allSatisfy { $0.path == root.path || $0.path.hasPrefix(root.path + "/") }
    }

    enum Contract: String {
        case doctor
        case login
        case enroll
        case download
        case start
    }

    static let pendingTrust = DaemonState.Trust(
        trustLevel: "self_signed",
        status: "pending",
        reason: "Waiting for coordinator trust",
        receivedAt: Date().timeIntervalSince1970
    )

    private func markMachineTruth(_ name: String) throws {
        try Data().write(to: machineDirectory.appendingPathComponent(name), options: .atomic)
    }

    private func writeDaemonState(trust: DaemonState.Trust?) throws {
        let now = Date().timeIntervalSince1970
        DaemonStateFile.write(
            DaemonState(
                pid: Int32(ProcessInfo.processInfo.processIdentifier),
                version: "0.0.0-fresh-install-test",
                writtenAt: now,
                startedAt: now - 1,
                trust: trust,
                currentModel: Self.modelID,
                warmModels: [Self.modelID],
                inferenceActive: true,
                identity: .init(providerName: "Fresh Install Test Mac", operatorAddress: "acct-test")
            ),
            to: stateFile
        )
        guard DaemonStateFile.read(from: stateFile) != nil else {
            throw HarnessError.couldNotWrite(stateFile)
        }
    }

    private func writeLocalEndpoint() throws {
        let info = LocalEndpointInfo(
            host: "127.0.0.1",
            port: 18_080,
            apiKey: "fresh-install-test-only",
            version: "0.0.0-fresh-install-test",
            pid: Int32(ProcessInfo.processInfo.processIdentifier),
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(info)
        try data.write(
            to: localDirectory.appendingPathComponent("local.json"),
            options: .atomic
        )
    }

    private static func safeName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(value.unicodeScalars.map {
            allowed.contains($0) ? Character(String($0)) : "-"
        })
    }

    enum HarnessError: Error {
        case couldNotWrite(URL)
    }
}
