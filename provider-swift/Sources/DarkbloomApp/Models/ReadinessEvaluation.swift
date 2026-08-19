import Foundation

struct ReadinessMachineFacts: Equatable, Sendable {
    static let minimumMemoryBytes: UInt64 = 8 * 1_073_741_824
    static let minimumFreeStorageBytes: UInt64 = 10 * 1_073_741_824

    let isAppleSilicon: Bool
    let physicalMemoryBytes: UInt64?
    let availableStorageBytes: UInt64?

    static var live: Self {
        #if arch(arm64)
        let isAppleSilicon = true
        #else
        let isAppleSilicon = false
        #endif

        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: "/")
        let availableStorage = (attributes?[.systemFreeSize] as? NSNumber)?.uint64Value
        return Self(
            isAppleSilicon: isAppleSilicon,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            availableStorageBytes: availableStorage
        )
    }
}

struct ReadinessEvaluation: Equatable, Sendable {
    struct Item: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let detail: String
        let action: String?
        let state: SetupItemState
        let doctorCheckIDs: [String]
    }

    let phase: ReadinessPhase
    let items: [Item]

    var completedCount: Int {
        items.filter { $0.state == .complete || $0.state == .advisory }.count
    }
}

enum ReadinessEvaluator {
    // These are stable `doctor --json` ids, not title/substring routing.
    private enum CheckID {
        static let hardware = "hardware"
        static let metalGPU = "metal-gpu"
        static let macOS = "macos"
        static let secureEnclave = "attestationKey.se-key-sign-test"
        static let sip = "sip"
        static let authenticatedRoot = "authenticated-root"
    }

    static func evaluate(
        report: DoctorJSONReport,
        facts: ReadinessMachineFacts
    ) -> ReadinessEvaluation {
        let checks = Dictionary(report.checks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let architectureChecks = requiredChecks([CheckID.hardware, CheckID.metalGPU], in: checks)
        let architectureOK = facts.isAppleSilicon && architectureChecks.allPassed
        let architecture = ReadinessEvaluation.Item(
            id: "apple-silicon",
            title: "Apple silicon",
            detail: architectureOK
                ? detail(for: CheckID.hardware, in: checks, fallback: "Apple silicon detected")
                : failureDetail(
                    checks: architectureChecks.checks,
                    fallback: facts.isAppleSilicon
                        ? "The system check could not confirm a usable Apple GPU."
                        : "This Mac is not running on Apple silicon."
                ),
            action: architectureOK ? nil : advice(from: architectureChecks.checks)
                ?? "Darkbloom requires an Apple silicon Mac with a working Metal GPU.",
            state: architectureOK ? .complete : .issue,
            doctorCheckIDs: [CheckID.hardware, CheckID.metalGPU]
        )

        let macOSCheck = requiredChecks([CheckID.macOS], in: checks)
        let macOSOK = macOSCheck.allPassed
        let macOS = ReadinessEvaluation.Item(
            id: "supported-macos",
            title: "macOS",
            detail: macOSOK
                ? detail(for: CheckID.macOS, in: checks, fallback: "Supported macOS version")
                : failureDetail(checks: macOSCheck.checks, fallback: "A supported macOS version could not be confirmed."),
            action: macOSOK ? nil : advice(from: macOSCheck.checks)
                ?? "Update this Mac to macOS Sonoma 14 or later, then run the check again.",
            state: macOSOK ? .complete : .issue,
            doctorCheckIDs: [CheckID.macOS]
        )

        let enclaveCheck = requiredChecks([CheckID.secureEnclave], in: checks)
        let enclaveOK = enclaveCheck.allPassed
        let enclave = ReadinessEvaluation.Item(
            id: "secure-enclave",
            title: "Secure Enclave",
            detail: enclaveOK
                ? detail(for: CheckID.secureEnclave, in: checks, fallback: "Private identity is available")
                : failureDetail(checks: enclaveCheck.checks, fallback: "The Secure Enclave signing check was not reported."),
            action: enclaveOK ? nil : advice(from: enclaveCheck.checks)
                ?? "Reinstall the official signed Darkbloom app, then run the check again.",
            state: enclaveOK ? .complete : .issue,
            doctorCheckIDs: [CheckID.secureEnclave]
        )

        let memoryBytes = facts.physicalMemoryBytes ?? memoryBytes(from: checks[CheckID.hardware]?.detail)
        let memoryOK = memoryBytes.map { $0 >= ReadinessMachineFacts.minimumMemoryBytes } == true
        let memory = ReadinessEvaluation.Item(
            id: "unified-memory",
            title: "Unified memory",
            detail: memoryBytes.map {
                "\(byteCount($0)) detected; 8 GB minimum"
            } ?? "Could not determine installed memory; 8 GB is required.",
            action: memoryOK ? nil : "Use an Apple silicon Mac with at least 8 GB of unified memory.",
            state: memoryOK ? .complete : .issue,
            doctorCheckIDs: [CheckID.hardware]
        )

        let storageBytes = facts.availableStorageBytes
        let storageOK = storageBytes.map { $0 >= ReadinessMachineFacts.minimumFreeStorageBytes } == true
        let storage = ReadinessEvaluation.Item(
            id: "available-storage",
            title: "Available storage",
            detail: storageBytes.map {
                "\(byteCount($0)) available; 10 GB minimum before model selection"
            } ?? "Could not determine available storage.",
            action: storageOK ? nil : "Free at least 10 GB, then run the check again. The exact model download size is checked during model selection.",
            state: storageOK ? .complete : .issue,
            doctorCheckIDs: []
        )

        let bootChecks = requiredChecks([CheckID.sip, CheckID.authenticatedRoot], in: checks)
        let bootOK = bootChecks.allPassed
        let boot = ReadinessEvaluation.Item(
            id: "boot-security",
            title: "Boot security",
            detail: bootOK
                ? "System Integrity Protection and authenticated root are enabled."
                : failureDetail(checks: bootChecks.checks, fallback: "The local boot-security posture could not be confirmed."),
            action: bootOK ? nil : advice(from: bootChecks.checks)
                ?? "Restore full boot security and enable System Integrity Protection, then run the check again.",
            state: bootOK ? .complete : .issue,
            doctorCheckIDs: [CheckID.sip, CheckID.authenticatedRoot]
        )

        let items = [architecture, macOS, enclave, memory, storage, boot]
        let phase: ReadinessPhase
        if !architectureOK {
            phase = .unsupportedMac
        } else if !memoryOK {
            phase = .insufficientMemory
        } else if !storageOK {
            phase = storageBytes == nil ? .unavailable : .insufficientStorage
        } else if !macOSOK || !enclaveOK || !bootOK {
            phase = .requirementsFailed
        } else {
            phase = .ready
        }
        return ReadinessEvaluation(phase: phase, items: items)
    }

    static func unavailable(_ message: String) -> ReadinessEvaluation {
        ReadinessEvaluation(
            phase: .unavailable,
            items: [
                ReadinessEvaluation.Item(id: "apple-silicon", title: "Apple silicon", detail: message, action: "Run the system check again.", state: .issue, doctorCheckIDs: [CheckID.hardware, CheckID.metalGPU]),
                ReadinessEvaluation.Item(id: "supported-macos", title: "macOS", detail: "Waiting for the system check", action: nil, state: .waiting, doctorCheckIDs: [CheckID.macOS]),
                ReadinessEvaluation.Item(id: "secure-enclave", title: "Secure Enclave", detail: "Waiting for the system check", action: nil, state: .waiting, doctorCheckIDs: [CheckID.secureEnclave]),
                ReadinessEvaluation.Item(id: "unified-memory", title: "Unified memory", detail: "Waiting for the system check", action: nil, state: .waiting, doctorCheckIDs: [CheckID.hardware]),
                ReadinessEvaluation.Item(id: "available-storage", title: "Available storage", detail: "Waiting for the system check", action: nil, state: .waiting, doctorCheckIDs: []),
                ReadinessEvaluation.Item(id: "boot-security", title: "Boot security", detail: "Waiting for the system check", action: nil, state: .waiting, doctorCheckIDs: [CheckID.sip, CheckID.authenticatedRoot]),
            ]
        )
    }

    private struct RequiredChecks {
        let checks: [DoctorJSONReport.Check]
        let expectedCount: Int

        var allPassed: Bool {
            checks.count == expectedCount && checks.allSatisfy { $0.status == "pass" }
        }
    }

    private static func requiredChecks(
        _ ids: [String],
        in checks: [String: DoctorJSONReport.Check]
    ) -> RequiredChecks {
        RequiredChecks(checks: ids.compactMap { checks[$0] }, expectedCount: ids.count)
    }

    private static func detail(
        for id: String,
        in checks: [String: DoctorJSONReport.Check],
        fallback: String
    ) -> String {
        checks[id]?.detail ?? fallback
    }

    private static func failureDetail(
        checks: [DoctorJSONReport.Check],
        fallback: String
    ) -> String {
        let failures = checks
            .filter { $0.status != "pass" }
            .map { "\($0.title): \($0.detail)" }
        return failures.isEmpty ? fallback : failures.joined(separator: " ")
    }

    private static func advice(from checks: [DoctorJSONReport.Check]) -> String? {
        checks.compactMap(\.advice).first
    }

    private static func memoryBytes(from detail: String?) -> UInt64? {
        guard let detail,
              let match = detail.firstMatch(of: /([0-9]+) GB RAM/),
              let gigabytes = UInt64(match.1)
        else { return nil }
        return gigabytes * 1_073_741_824
    }

    private static func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .binary)
    }
}

extension DoctorJSONReport {
    func check(id: String) -> Check? {
        checks.first { $0.id == id }
    }

    var reportsLinkedAccount: Bool {
        check(id: "account-link")?.status == "pass"
    }

    var reportsDarkbloomEnrollment: Bool {
        check(id: "mdm-enrollment")?.status == "pass"
    }
}
