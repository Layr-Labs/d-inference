import Foundation

/// Bridge from the app to `darkbloom earnings --json`: the CLI resolves the
/// configured coordinator URL and the linked account (`~/.darkbloom/provider_account`),
/// fetches `GET /v1/provider/earnings?wallet=<address>`, and prints the
/// payload; the app decodes + maps it (see `ContributionsStore`).
///
/// Wire contract (coordinator's ProviderEarningsResponse):
/// `{"balance_micro_usd": n, "balance_usd": "…", "total_earned_micro_usd": n,
/// "total_earned_usd": "…", "total_jobs": n, "payouts": [ {id,
/// provider_address, amount_micro_usd, model, job_id, timestamp, settled} ],
/// "ledger": [ {id, account_id, type, amount_micro_usd, balance_after,
/// reference, created_at} ] }`.
/// `ledger` can be JSON null (store-with-no-rows marshals a nil slice);
/// `payouts[].model` is absent on rows the handler reconstructed from the
/// ledger fallback.
struct ContributionsEarningsPayload: Codable, Equatable, Sendable {
    /// The queried wallet address, echoed by the CLI on top of the
    /// coordinator payload so records key to the account that earned them.
    /// nil only when decoding a bare coordinator response (tests).
    var wallet: String?
    struct Payout: Codable, Equatable, Sendable {
        var id: Int64
        var providerAddress: String?
        var amountMicroUSD: Int64
        var model: String?
        var jobID: String?
        var timestamp: Date?
        var settled: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case providerAddress = "provider_address"
            case amountMicroUSD = "amount_micro_usd"
            case model
            case jobID = "job_id"
            case timestamp
            case settled
        }

        init(
            id: Int64,
            providerAddress: String?,
            amountMicroUSD: Int64,
            model: String?,
            jobID: String?,
            timestamp: Date?,
            settled: Bool
        ) {
            self.id = id
            self.providerAddress = providerAddress
            self.amountMicroUSD = amountMicroUSD
            self.model = model
            self.jobID = jobID
            self.timestamp = timestamp
            self.settled = settled
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(Int64.self, forKey: .id) ?? 0
            providerAddress = try container.decodeIfPresent(String.self, forKey: .providerAddress)
            amountMicroUSD = try container.decodeIfPresent(Int64.self, forKey: .amountMicroUSD) ?? 0
            model = try container.decodeIfPresent(String.self, forKey: .model)
            jobID = try container.decodeIfPresent(String.self, forKey: .jobID)
            timestamp = try container.decodeIfPresent(ContributionsTimestamp.self, forKey: .timestamp)?.date
            settled = try container.decodeIfPresent(Bool.self, forKey: .settled) ?? false
        }

        // Timestamps mirror the coordinator's RFC3339 strings (the default
        // numeric Date strategy would make CLI --json and coordinator payloads
        // cross-incompatible; see the custom decode above).
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(providerAddress, forKey: .providerAddress)
            try container.encode(amountMicroUSD, forKey: .amountMicroUSD)
            try container.encodeIfPresent(model, forKey: .model)
            try container.encodeIfPresent(jobID, forKey: .jobID)
            try container.encodeIfPresent(timestamp.map(ContributionsTimestamp.init), forKey: .timestamp)
            try container.encode(settled, forKey: .settled)
        }
    }

    struct LedgerEntry: Codable, Equatable, Sendable {
        var id: Int64
        var accountID: String?
        var type: String
        var amountMicroUSD: Int64
        var balanceAfter: Int64
        var reference: String?
        var createdAt: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case accountID = "account_id"
            case type
            case amountMicroUSD = "amount_micro_usd"
            case balanceAfter = "balance_after"
            case reference
            case createdAt = "created_at"
        }

        init(
            id: Int64,
            accountID: String?,
            type: String,
            amountMicroUSD: Int64,
            balanceAfter: Int64,
            reference: String?,
            createdAt: Date?
        ) {
            self.id = id
            self.accountID = accountID
            self.type = type
            self.amountMicroUSD = amountMicroUSD
            self.balanceAfter = balanceAfter
            self.reference = reference
            self.createdAt = createdAt
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(Int64.self, forKey: .id) ?? 0
            accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
            type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
            amountMicroUSD = try container.decodeIfPresent(Int64.self, forKey: .amountMicroUSD) ?? 0
            balanceAfter = try container.decodeIfPresent(Int64.self, forKey: .balanceAfter) ?? 0
            reference = try container.decodeIfPresent(String.self, forKey: .reference)
            createdAt = try container.decodeIfPresent(ContributionsTimestamp.self, forKey: .createdAt)?.date
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(accountID, forKey: .accountID)
            try container.encode(type, forKey: .type)
            try container.encode(amountMicroUSD, forKey: .amountMicroUSD)
            try container.encode(balanceAfter, forKey: .balanceAfter)
            try container.encodeIfPresent(reference, forKey: .reference)
            try container.encodeIfPresent(createdAt.map(ContributionsTimestamp.init), forKey: .createdAt)
        }
    }

    var balanceMicroUSD: Int64
    var totalEarnedMicroUSD: Int64
    var totalJobs: Int
    var payouts: [Payout]
    var ledger: [LedgerEntry]

    enum CodingKeys: String, CodingKey {
        case wallet
        case balanceMicroUSD = "balance_micro_usd"
        case totalEarnedMicroUSD = "total_earned_micro_usd"
        case totalJobs = "total_jobs"
        case payouts
        case ledger
    }

    init(
        wallet: String?,
        balanceMicroUSD: Int64,
        totalEarnedMicroUSD: Int64,
        totalJobs: Int,
        payouts: [Payout],
        ledger: [LedgerEntry]
    ) {
        self.wallet = wallet
        self.balanceMicroUSD = balanceMicroUSD
        self.totalEarnedMicroUSD = totalEarnedMicroUSD
        self.totalJobs = totalJobs
        self.payouts = payouts
        self.ledger = ledger
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        wallet = try container.decodeIfPresent(String.self, forKey: .wallet)
        balanceMicroUSD = try container.decodeIfPresent(Int64.self, forKey: .balanceMicroUSD) ?? 0
        totalEarnedMicroUSD = try container.decodeIfPresent(Int64.self, forKey: .totalEarnedMicroUSD) ?? 0
        totalJobs = try container.decodeIfPresent(Int.self, forKey: .totalJobs) ?? 0
        payouts = try container.decodeIfPresent([Payout].self, forKey: .payouts) ?? []
        ledger = try container.decodeIfPresent([LedgerEntry].self, forKey: .ledger) ?? []
    }
}

/// RFC3339/RFC3339Nano tolerant timestamp (Go `time.Time`).
struct ContributionsTimestamp: Codable, Equatable, Sendable {
    let date: Date

    init(_ date: Date) { self.date = date }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            self.date = date
            return
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: raw) {
            self.date = date
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected RFC3339 timestamp, got '\(raw)'")
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try container.encode(formatter.string(from: date))
    }
}

protocol ContributionsCLIRunning: Sendable {
    /// `darkbloom earnings --json`, decoded.
    func fetchEarnings() async throws -> ContributionsEarningsPayload
}

enum ContributionsCLIError: Error, Equatable, LocalizedError, Sendable {
    /// No `darkbloom` binary found in any known install location.
    case cliNotFound
    /// The CLI exited non-zero; the message carries its one-line stderr
    /// guidance verbatim ("run `darkbloom login`…", "could not reach the
    /// coordinator…"), so the UI shows exactly what a terminal user sees.
    case exited(Int32, message: String)
    /// The CLI did not finish within the bounded wait and was terminated.
    case timedOut(command: String)
    /// `--json` stdout could not be decoded into the earnings payload.
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            "The Darkbloom provider CLI is not installed, so earnings cannot be fetched."
        case .exited(let status, let message):
            message.isEmpty ? "The earnings command failed (exit \(status))." : message
        case .timedOut(let command):
            "The command `darkbloom \(command)` did not finish in time."
        case .invalidOutput(let detail):
            "The provider CLI returned unreadable earnings data (\(detail))."
        }
    }
}

private struct ContributionsCLIResult: Sendable, Equatable {
    var exitStatus: Int32
    var stdout: String
}

/// Locates and invokes the installed `darkbloom` binary. Self-contained
/// micro-runner (mirrors `ProcessAvailabilityCLI`'s, per slice guidance:
/// duplicate <30 lines rather than refactoring the shared lifecycle runner,
/// which discards stdout on purpose).
struct ProcessContributionsCLI: ContributionsCLIRunning {
    private let locator: any DarkbloomCLILocating
    private let timeout: Duration

    init(
        locator: any DarkbloomCLILocating = SystemDarkbloomCLILocator(),
        timeout: Duration = .seconds(30)
    ) {
        self.locator = locator
        self.timeout = timeout
    }

    func fetchEarnings() async throws -> ContributionsEarningsPayload {
        let result = try await invoke(arguments: ["earnings", "--json"])
        guard !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = result.stdout.data(using: .utf8)
        else {
            throw ContributionsCLIError.invalidOutput("empty stdout")
        }
        do {
            return try JSONDecoder().decode(ContributionsEarningsPayload.self, from: data)
        } catch {
            throw ContributionsCLIError.invalidOutput("\(error)")
        }
    }

    private func invoke(arguments: [String]) async throws -> ContributionsCLIResult {
        guard let executable = locator.locate() else {
            throw ContributionsCLIError.cliNotFound
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let stdout = ContributionsPipeCollector()
        let stderr = ContributionsPipeCollector()
        stdoutPipe.fileHandleForReading.readabilityHandler = { stdout.append($0.availableData) }
        stderrPipe.fileHandleForReading.readabilityHandler = { stderr.append($0.availableData) }

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<ContributionsCLIResult, any Error>) in
            let timedOut = ContributionsTimeoutFlag()
            process.terminationHandler = { process in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                // Drain both pipes post-termination: final bytes race the
                // readability callbacks and would otherwise be lost
                // (empty stdout parse on success, empty stderr message on failure).
                stdout.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                stderr.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                let command = arguments.joined(separator: " ")
                if timedOut.value {
                    continuation.resume(throwing: ContributionsCLIError.timedOut(command: command))
                    return
                }
                let status = process.terminationStatus
                if status == 0 {
                    continuation.resume(returning: ContributionsCLIResult(
                        exitStatus: status, stdout: stdout.text))
                } else {
                    continuation.resume(throwing: ContributionsCLIError.exited(status, message: stderr.lastLine))
                }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
                return
            }
            Task {
                try? await Task.sleep(for: timeout)
                timedOut.set()
                if process.isRunning { process.terminate() }
            }
        }
    }
}

/// Bounded stdout/stderr accumulator shared across readability callbacks.
private final class ContributionsPipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    /// Last non-empty line, retained for user-facing failure messages.
    var lastLine: String {
        text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .last ?? ""
    }
}

private final class ContributionsTimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}
