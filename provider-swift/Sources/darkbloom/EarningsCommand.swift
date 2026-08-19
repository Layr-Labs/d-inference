// Earnings command: `darkbloom earnings [--json]`.
//
// Fetches the coordinator's NO-AUTH provider earnings endpoint
// (`GET /v1/provider/earnings?wallet=<address>` — see coordinator/api
// consumer.go `handleProviderEarnings`). Providers identify by the payout
// address the coordinator credits: the account id minted at device login and
// returned by `POST /v1/device/token` as `account_id`, persisted locally at
// `~/.darkbloom/provider_account` (`ProviderAccountStore`). `--wallet`
// overrides for power users and scripts.
//
// The endpoint answers 200 with zeroed totals for an address it has never
// seen — "unknown provider" is NOT an HTTP error — so the failure paths that
// matter are transport (coordinator unreachable) and non-2xx.
//
// The single network hop is isolated behind `EarningsTransport` so tests
// drive the full command path against an in-memory stub.
import Foundation
import ArgumentParser
import ProviderCore

// MARK: - Wire model (mirrors coordinator's ProviderEarningsResponse)

/// `GET /v1/provider/earnings` response body. Tolerant on the fields the
/// handler can emit as JSON `null` (`payouts` is always an array, `ledger`
/// may be `null` when the store returns no rows) and on payout rows
/// reconstructed from ledger entries (which carry no model).
struct ProviderEarningsReport: Codable, Equatable, Sendable {
    /// The queried wallet address, ECHOED by `darkbloom earnings --json` on
    /// top of the coordinator payload (the coordinator response itself does
    /// not carry it). Self-describing output: the Darkbloom app keys records
    /// by it without re-deriving the address. nil when decoding a bare
    /// coordinator payload (never emitted as null).
    var wallet: String?
    var balanceMicroUSD: Int64
    var balanceUSD: String
    var totalEarnedMicroUSD: Int64
    var totalEarnedUSD: String
    var totalJobs: Int
    var payouts: [Payout]
    var ledger: [LedgerEntry]

    enum CodingKeys: String, CodingKey {
        case wallet
        case balanceMicroUSD = "balance_micro_usd"
        case balanceUSD = "balance_usd"
        case totalEarnedMicroUSD = "total_earned_micro_usd"
        case totalEarnedUSD = "total_earned_usd"
        case totalJobs = "total_jobs"
        case payouts
        case ledger
    }

    init(
        wallet: String?,
        balanceMicroUSD: Int64,
        balanceUSD: String,
        totalEarnedMicroUSD: Int64,
        totalEarnedUSD: String,
        totalJobs: Int,
        payouts: [Payout],
        ledger: [LedgerEntry]
    ) {
        self.wallet = wallet
        self.balanceMicroUSD = balanceMicroUSD
        self.balanceUSD = balanceUSD
        self.totalEarnedMicroUSD = totalEarnedMicroUSD
        self.totalEarnedUSD = totalEarnedUSD
        self.totalJobs = totalJobs
        self.payouts = payouts
        self.ledger = ledger
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        wallet = try container.decodeIfPresent(String.self, forKey: .wallet)
        balanceMicroUSD = try container.decodeIfPresent(Int64.self, forKey: .balanceMicroUSD) ?? 0
        balanceUSD = try container.decodeIfPresent(String.self, forKey: .balanceUSD) ?? "0"
        totalEarnedMicroUSD = try container.decodeIfPresent(Int64.self, forKey: .totalEarnedMicroUSD) ?? 0
        totalEarnedUSD = try container.decodeIfPresent(String.self, forKey: .totalEarnedUSD) ?? "0"
        totalJobs = try container.decodeIfPresent(Int.self, forKey: .totalJobs) ?? 0
        payouts = try container.decodeIfPresent([Payout].self, forKey: .payouts) ?? []
        ledger = try container.decodeIfPresent([LedgerEntry].self, forKey: .ledger) ?? []
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(wallet, forKey: .wallet)
        try container.encode(balanceMicroUSD, forKey: .balanceMicroUSD)
        try container.encode(balanceUSD, forKey: .balanceUSD)
        try container.encode(totalEarnedMicroUSD, forKey: .totalEarnedMicroUSD)
        try container.encode(totalEarnedUSD, forKey: .totalEarnedUSD)
        try container.encode(totalJobs, forKey: .totalJobs)
        try container.encode(payouts, forKey: .payouts)
        try container.encode(ledger, forKey: .ledger)
    }

    /// A stored `ProviderPayout` row (or the handler's ledger-reconstructed
    /// equivalent). `model` is absent on reconstructed rows; `timestamp` is
    /// RFC3339 (Go `time.Time`).
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
            timestamp = try container.decodeIfPresent(GoTimestamp.self, forKey: .timestamp)?.date
            settled = try container.decodeIfPresent(Bool.self, forKey: .settled) ?? false
        }

        // Custom encode: Foundation's default Date strategy is
        // seconds-since-1970 (a NUMBER), but the coordinator-side contract
        // this payload mirrors — and the app-side decoder — reads RFC3339
        // strings. Encode through GoTimestamp so CLI `--json` output stays
        // decodable by the app.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(providerAddress, forKey: .providerAddress)
            try container.encode(amountMicroUSD, forKey: .amountMicroUSD)
            try container.encodeIfPresent(model, forKey: .model)
            try container.encodeIfPresent(jobID, forKey: .jobID)
            try container.encodeIfPresent(timestamp.map(GoTimestamp.init), forKey: .timestamp)
            try container.encode(settled, forKey: .settled)
        }
    }

    /// A server-side `store.LedgerEntry` row.
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
            createdAt = try container.decodeIfPresent(GoTimestamp.self, forKey: .createdAt)?.date
        }

        // See Payout.encode(to:) — timestamps stay RFC3339 strings.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(accountID, forKey: .accountID)
            try container.encode(type, forKey: .type)
            try container.encode(amountMicroUSD, forKey: .amountMicroUSD)
            try container.encode(balanceAfter, forKey: .balanceAfter)
            try container.encodeIfPresent(reference, forKey: .reference)
            try container.encodeIfPresent(createdAt.map(GoTimestamp.init), forKey: .createdAt)
        }
    }
}

/// Go `time.Time` values arrive as RFC3339/RFC3339Nano strings; accept both
/// (with and without fractional seconds) so `swift-corelibs-foundation` and
/// Darwin formatters agree.
struct GoTimestamp: Codable, Equatable, Sendable {
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

// MARK: - Transport

/// The single network hop `darkbloom earnings` performs. Tests substitute an
/// in-memory stub; production uses URLSession.
typealias EarningsTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

enum EarningsFetchError: Error, Equatable, CustomStringConvertible, Sendable {
    case coordinatorUnreachable(baseURL: String, detail: String)
    case httpError(status: Int, baseURL: String)
    case invalidResponse(baseURL: String)

    var description: String {
        switch self {
        case .coordinatorUnreachable(let baseURL, let detail):
            return "Could not reach the coordinator at \(baseURL) (\(detail)). Check your connection and try again."
        case .httpError(let status, let baseURL):
            return "Coordinator at \(baseURL) answered HTTP \(status) for /v1/provider/earnings. If this persists, report it to Darkbloom."
        case .invalidResponse(let baseURL):
            return "Coordinator at \(baseURL) returned an unreadable earnings response."
        }
    }
}

/// Build the earnings request: `{coordinatorHTTPBase(url)}/v1/provider/earnings?wallet=<address>`.
/// Throws (not silently rewrites) when the configured URL has no usable host.
func makeEarningsRequest(coordinatorURL: String, wallet: String) throws -> URLRequest {
    let baseURL = coordinatorHTTPBase(coordinatorURL)
    guard var components = URLComponents(string: baseURL),
          components.host != nil
    else {
        throw ValidationError("Configured coordinator URL '\(coordinatorURL)' is not a usable HTTP base.")
    }
    components.path = "/v1/provider/earnings"
    components.queryItems = [URLQueryItem(name: "wallet", value: wallet)]
    guard let url = components.url else {
        throw ValidationError("Could not build the earnings URL for wallet '\(wallet)'.")
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    return request
}

/// Fetch + decode the earnings report against an arbitrary transport.
func fetchProviderEarnings(
    request: URLRequest,
    transport: @escaping EarningsTransport
) async throws -> ProviderEarningsReport {
    let baseURL = request.url.map { "\($0.scheme ?? "https")://\($0.host ?? "")" } ?? "coordinator"
    let (data, response): (Data, URLResponse)
    do {
        (data, response) = try await transport(request)
    } catch {
        throw EarningsFetchError.coordinatorUnreachable(
            baseURL: baseURL,
            detail: error.localizedDescription)
    }
    guard let http = response as? HTTPURLResponse else {
        throw EarningsFetchError.invalidResponse(baseURL: baseURL)
    }
    guard (200 ..< 300).contains(http.statusCode) else {
        throw EarningsFetchError.httpError(status: http.statusCode, baseURL: baseURL)
    }
    do {
        return try JSONDecoder().decode(ProviderEarningsReport.self, from: data)
    } catch {
        throw EarningsFetchError.invalidResponse(baseURL: baseURL)
    }
}

// MARK: - Command

struct Earnings: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "earnings",
        abstract: "Show this provider's earnings from the coordinator.",
        discussion: """
        Reads the coordinator's no-auth provider earnings endpoint
        (GET /v1/provider/earnings?wallet=<address>). The wallet address is
        the account this Mac was linked to via `darkbloom login`
        (~/.darkbloom/provider_account); override with --wallet.
        """
    )

    @OptionGroup var configOptions: ConfigOptions

    @Flag(name: .long, help: "Emit the earnings payload as JSON.")
    var json = false

    @Option(name: .long, help: "Wallet/account address override; defaults to the account linked via `darkbloom login`.")
    var wallet: String?

    mutating func run() async throws {
        // Read-only: never migrate the config on a reporting path.
        let snapshot = try loadRuntimeSnapshot(configPath: configOptions.config, migrateOnDisk: false)

        let address = wallet ?? ProviderAccountStore.load()
        guard let address, !address.isEmpty else {
            printError("No linked account found for this Mac. Run `darkbloom login` to link it, or pass --wallet <address>.")
            throw ExitCode.failure
        }

        let request = try makeEarningsRequest(
            coordinatorURL: snapshot.config.coordinator.url,
            wallet: address)
        let transport: EarningsTransport = { try await URLSession.shared.data(for: $0) }

        let report: ProviderEarningsReport
        do {
            var fetched = try await fetchProviderEarnings(request: request, transport: transport)
            fetched.wallet = address
            report = fetched
        } catch let error as EarningsFetchError {
            printError(error.description)
            throw ExitCode.failure
        }

        if json {
            try printJSON(report)
            return
        }

        print("Provider earnings (wallet: \(address))")
        print("  Pending balance: $\(report.balanceUSD) (\(report.balanceMicroUSD) µ$)")
        print("  Total earned:    $\(report.totalEarnedUSD) across \(report.totalJobs) jobs")
        if report.payouts.isEmpty {
            print("  No payout records yet.")
        } else {
            print("  Recent payouts: \(report.payouts.count) (see --json for the full ledger)")
        }
    }
}
