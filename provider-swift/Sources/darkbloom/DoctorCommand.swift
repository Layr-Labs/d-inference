import Foundation
import ArgumentParser
import ProviderCore

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run local provider diagnostics.",
        discussion: "Diagnostics are read-only except for subprocesses used by public ProviderCore checks."
    )

    @OptionGroup var configOptions: ConfigOptions

    @Flag(help: "Treat warning-level checks as failures.")
    var strict = false

    @Option(help: "Override coordinator HTTP/WS URL for network diagnostics.")
    var coordinator: String?

    @Flag(help: "Print local provider identifiers used for support/debugging.")
    var support = false

    mutating func run() async throws {
        await runUpdateBannerIfEnabled()

        let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
        var checks = buildDoctorChecks(snapshot: snapshot)
        checks.append(contentsOf: await buildCoordinatorDoctorChecks(
            snapshot: snapshot,
            coordinatorOverride: coordinator
        ))

        // Operator-facing diagnosis: trust reason, SE key, model fit, runtime,
        // billing, version — the "why am I / aren't I earning?" answers.
        let diagnosis = await DoctorRunner.buildOperatorDiagnosis(
            snapshot: snapshot,
            coordinatorURL: coordinator ?? snapshot.config.coordinator.url
        )

        print("darkbloom doctor \(ProviderCore.version)")
        print("Config: \(describeConfigPath(snapshot))")
        let daemonState = DaemonStateFile.read()
        let daemonRunning = daemonState.map { daemonProcessAlive(pid: $0.pid) } ?? false
        print("Daemon: \(daemonRunning ? "running" : "NOT running — run `darkbloom start`")")

        // The high-signal diagnosis first (sectioned, with fixes).
        let rendered = DiagnosticReportRenderer.render(diagnosis)
        if !rendered.isEmpty { print(rendered) }

        // Then the detailed low-level checks.
        print("")
        print("DETAILED CHECKS")
        for check in checks {
            print("  \(check.status.marker) \(check.name): \(check.detail)")
        }
        if support {
            print("")
            print("Support")
            print("  coordinator: \(coordinatorHTTPBase(coordinator ?? snapshot.config.coordinator.url))")
            print("  serial: \(macHardwareSerialNumber() ?? "<unavailable>")")
            print("  auth token: \(AuthTokenStore.load() == nil ? "missing" : "present")")
            print("  mdm enrolled: \(describeMDMEnrollment(checkMDMEnrollment(coordinatorURL: coordinator ?? snapshot.config.coordinator.url)))")
            print("  pid file: \(ProcessLifecycle.defaultPIDFile().path)")
        }

        let hasFailure = checks.contains { $0.status == .fail }
            || diagnosis.contains { $0.level == .fail }
        let hasWarning = checks.contains { $0.status == .warn }
            || diagnosis.contains { $0.level == .warn }

        if hasFailure || (strict && hasWarning) {
            throw ExitCode.failure
        }
    }
}

// MARK: - Doctor

enum CheckStatus: Equatable {
    case pass
    case warn
    case fail

    var marker: String {
        switch self {
        case .pass: return "[PASS]"
        case .warn: return "[WARN]"
        case .fail: return "[FAIL]"
        }
    }
}

struct DoctorCheck {
    let name: String
    let status: CheckStatus
    let detail: String
}

func buildDoctorChecks(snapshot: RuntimeSnapshot) -> [DoctorCheck] {
    var checks: [DoctorCheck] = []

    if let hardware = snapshot.hardware {
        checks.append(.init(
            name: "hardware",
            status: .pass,
            detail: "\(hardware.chipName), \(hardware.memoryGb) GB RAM, \(hardware.gpuCores) GPU cores"
        ))
    } else {
        checks.append(.init(
            name: "hardware",
            status: .fail,
            detail: snapshot.hardwareError?.localizedDescription ?? "hardware detection failed"
        ))
    }

    let metal = GPUEnforcement.probeMetal()
    if metal.isAvailable {
        let working = metal.recommendedMaxWorkingSetSizeBytes / (1024 * 1024 * 1024)
        let device = metal.deviceName ?? "unknown"
        checks.append(.init(
            name: "metal gpu",
            status: .pass,
            detail: "\(device), \(working) GB working set"
        ))
    } else {
        checks.append(.init(
            name: "metal gpu",
            status: .fail,
            detail: "Metal device not found; provider refuses to run on CPU"
        ))
    }

    checks.append(.init(
        name: "config",
        status: snapshot.configFileExists ? .pass : .warn,
        detail: snapshot.configFileExists ? "loaded" : "missing, defaults are in memory only"
    ))

    if let cacheDir = ModelScanner.defaultCacheDirectory(),
       FileManager.default.fileExists(atPath: cacheDir.path) {
        checks.append(.init(
            name: "huggingface cache",
            status: .pass,
            detail: cacheDir.path
        ))
    } else {
        checks.append(.init(
            name: "huggingface cache",
            status: .warn,
            detail: "not found"
        ))
    }

    checks.append(.init(
        name: "local mlx models",
        status: snapshot.models.isEmpty ? .warn : .pass,
        detail: "\(snapshot.models.count) discovered"
    ))

    let sipEnabled = checkSIPEnabled()
    checks.append(.init(
        name: "sip",
        status: sipEnabled ? .pass : .fail,
        detail: sipEnabled ? "enabled" : "disabled"
    ))

    let rdmaDisabled = checkRDMADisabled()
    checks.append(.init(
        name: "rdma",
        status: rdmaDisabled ? .pass : .warn,
        detail: rdmaDisabled ? "disabled" : "enabled; allowed for RDMA-aware runtimes"
    ))

    let secureBoot = checkSecureBootEnabled()
    checks.append(.init(
        name: "secure boot",
        status: secureBoot ? .pass : .warn,
        detail: secureBoot ? "enabled" : "not confirmed"
    ))

    let authenticatedRoot = checkAuthenticatedRootEnabled()
    checks.append(.init(
        name: "authenticated root",
        status: authenticatedRoot ? .pass : .warn,
        detail: authenticatedRoot ? "enabled" : "not confirmed"
    ))

    let hardenedRuntime = checkHardenedRuntimeEnabled()
    checks.append(.init(
        name: "hardened runtime",
        status: hardenedRuntime ? .pass : .warn,
        detail: hardenedRuntime ? "enabled" : "not confirmed for this executable"
    ))

    let debuggerAttached = checkDebuggerAttached()
    checks.append(.init(
        name: "debugger",
        status: debuggerAttached ? .fail : .pass,
        detail: debuggerAttached ? "attached" : "not attached"
    ))

    if let binaryHash = selfBinaryHash() {
        checks.append(.init(
            name: "binary hash",
            status: .pass,
            detail: binaryHash
        ))
    } else {
        checks.append(.init(
            name: "binary hash",
            status: .warn,
            detail: "could not compute"
        ))
    }

    return checks
}

private struct ProviderAttestationList: Decodable {
    let providers: [ProviderAttestation]
}

private struct ProviderAttestation: Decodable {
    let providerID: String
    let chipName: String
    let hardwareModel: String
    let serialNumber: String
    let trustLevel: String
    let status: String
    let mdmVerified: Bool
    let acmeVerified: Bool
    let mdaVerified: Bool
    let secureEnclave: Bool
    let sipEnabled: Bool
    let secureBootEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case chipName = "chip_name"
        case hardwareModel = "hardware_model"
        case serialNumber = "serial_number"
        case trustLevel = "trust_level"
        case status
        case mdmVerified = "mdm_verified"
        case acmeVerified = "acme_verified"
        case mdaVerified = "mda_verified"
        case secureEnclave = "secure_enclave"
        case sipEnabled = "sip_enabled"
        case secureBootEnabled = "secure_boot_enabled"
    }
}

func buildCoordinatorDoctorChecks(
    snapshot: RuntimeSnapshot,
    coordinatorOverride: String?
) async -> [DoctorCheck] {
    let base = coordinatorHTTPBase(coordinatorOverride ?? snapshot.config.coordinator.url)
    var checks: [DoctorCheck] = []

    checks.append(.init(
        name: "account link",
        status: AuthTokenStore.load() == nil ? .warn : .pass,
        detail: AuthTokenStore.load() == nil ? "not logged in; run darkbloom login" : "auth token present"
    ))

    switch checkMDMEnrollment(coordinatorURL: coordinatorOverride ?? snapshot.config.coordinator.url) {
    case .enrolledDarkbloom:
        checks.append(.init(
            name: "mdm enrollment", status: .pass, detail: "Darkbloom profile installed"))
    case .enrolledOtherMDM(let serverURL):
        checks.append(.init(
            name: "mdm enrollment", status: .warn,
            detail: "enrolled in another MDM (\(serverURL)) — Darkbloom hardware trust unavailable on this Mac"))
    case .notEnrolled:
        checks.append(.init(
            name: "mdm enrollment", status: .warn,
            detail: "not enrolled; hardware trust may remain pending"))
    case .checkFailed:
        checks.append(.init(
            name: "mdm enrollment", status: .warn,
            detail: "could not determine (profiles tool failed) — check System Settings → Device Management"))
    }

    do {
        _ = try await doctorFetch(urlString: "\(base)/health", timeout: 5)
        checks.append(.init(
            name: "coordinator health",
            status: .pass,
            detail: base
        ))
    } catch {
        checks.append(.init(
            name: "coordinator health",
            status: .fail,
            detail: "\(base): \(error.localizedDescription)"
        ))
        return checks
    }

    guard let serial = macHardwareSerialNumber(), !serial.isEmpty else {
        checks.append(.init(
            name: "coordinator trust",
            status: .warn,
            detail: "local serial number unavailable"
        ))
        return checks
    }

    do {
        let data = try await doctorFetch(urlString: "\(base)/v1/providers/attestation", timeout: 8)
        let decoded = try JSONDecoder().decode(ProviderAttestationList.self, from: data)
        let matches = decoded.providers.filter { $0.serialNumber == serial }
        guard let provider = matches.sorted(by: providerTrustSort).first else {
            checks.append(.init(
                name: "coordinator trust",
                status: .warn,
                detail: "no live provider record for this serial yet"
            ))
            return checks
        }

        let status: CheckStatus = provider.trustLevel == "hardware" ? .pass : .warn
        let proofs = [
            provider.mdmVerified ? "mdm" : nil,
            provider.acmeVerified ? "acme" : nil,
            provider.mdaVerified ? "mda" : nil,
        ].compactMap { $0 }.joined(separator: ",")
        let proofText = proofs.isEmpty ? "self-signed only" : proofs
        checks.append(.init(
            name: "coordinator trust",
            status: status,
            detail: "\(provider.providerID) \(provider.status), trust=\(provider.trustLevel), proofs=\(proofText)"
        ))
    } catch {
        checks.append(.init(
            name: "coordinator trust",
            status: .warn,
            detail: "could not read attestation endpoint: \(error.localizedDescription)"
        ))
    }

    return checks
}

private func providerTrustSort(_ lhs: ProviderAttestation, _ rhs: ProviderAttestation) -> Bool {
    func score(_ provider: ProviderAttestation) -> Int {
        var total = 0
        if provider.status == "online" { total += 100 }
        if provider.trustLevel == "hardware" { total += 50 }
        if provider.mdaVerified { total += 10 }
        if provider.acmeVerified { total += 5 }
        if provider.mdmVerified { total += 5 }
        return total
    }
    return score(lhs) > score(rhs)
}

private func doctorFetch(urlString: String, timeout: TimeInterval) async throws -> Data {
    guard let url = URL(string: urlString) else {
        throw URLError(.badURL)
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await URLSession.shared.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        throw URLError(.badServerResponse)
    }
    return data
}


/// One-line human description of the MDM enrollment state for `doctor --support`.
func describeMDMEnrollment(_ state: MDMEnrollmentState) -> String {
    switch state {
    case .enrolledDarkbloom: return "yes (darkbloom)"
    case .enrolledOtherMDM(let serverURL): return "other MDM (\(serverURL))"
    case .notEnrolled: return "no"
    case .checkFailed: return "unknown (profiles tool failed)"
    }
}
