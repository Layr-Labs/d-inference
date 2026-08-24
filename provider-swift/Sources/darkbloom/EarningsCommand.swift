import ArgumentParser
import Foundation
import ProviderCore

typealias EarningsTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

enum EarningsFetchError: Error, Equatable, CustomStringConvertible, Sendable {
    case coordinatorUnreachable(baseURL: String, detail: String)
    case authenticationRejected(status: Int)
    case httpError(status: Int, endpoint: String, baseURL: String)
    case invalidResponse(endpoint: String, baseURL: String)

    var description: String {
        switch self {
        case .coordinatorUnreachable(let baseURL, let detail):
            return "Could not reach the coordinator at \(baseURL) (\(detail)). Check your connection and try again."
        case .authenticationRejected:
            return "This Mac's provider login is no longer valid. Run `darkbloom logout`, then `darkbloom login` to link it again."
        case .httpError(let status, let endpoint, let baseURL):
            return "Coordinator at \(baseURL) answered HTTP \(status) for \(endpoint). If this persists, report it to Darkbloom."
        case .invalidResponse(let endpoint, let baseURL):
            return "Coordinator at \(baseURL) returned an unreadable response for \(endpoint)."
        }
    }
}

func makeAccountEarningsRequest(
    coordinatorURL: String,
    authToken: String,
    limit: Int = 1_000
) throws -> URLRequest {
    guard !authToken.isEmpty else {
        throw ValidationError("A provider login token is required for linked-account earnings.")
    }
    let url = try earningsURL(
        coordinatorURL: coordinatorURL,
        path: "/v1/provider/account-earnings",
        queryItems: [URLQueryItem(name: "limit", value: String(limit))]
    )
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
    return request
}

func makeLegacyWalletEarningsRequest(
    coordinatorURL: String,
    wallet: String
) throws -> URLRequest {
    let url = try earningsURL(
        coordinatorURL: coordinatorURL,
        path: "/v1/provider/earnings",
        queryItems: [URLQueryItem(name: "wallet", value: wallet)]
    )
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    return request
}

private func earningsURL(
    coordinatorURL: String,
    path: String,
    queryItems: [URLQueryItem]
) throws -> URL {
    let baseURL = coordinatorHTTPBase(coordinatorURL)
    guard var components = URLComponents(string: baseURL),
          components.host != nil
    else {
        throw ValidationError("Configured coordinator URL '\(coordinatorURL)' is not a usable HTTP base.")
    }
    components.path = path
    components.queryItems = queryItems
    guard let url = components.url else {
        throw ValidationError("Could not build the coordinator earnings URL.")
    }
    return url
}

func fetchAccountEarnings(
    request: URLRequest,
    transport: @escaping EarningsTransport
) async throws -> ProviderAccountEarningsReport {
    let (data, http) = try await earningsResponse(request: request, transport: transport)
    if http.statusCode == 401 || http.statusCode == 403 {
        throw EarningsFetchError.authenticationRejected(status: http.statusCode)
    }
    guard (200 ..< 300).contains(http.statusCode) else {
        throw EarningsFetchError.httpError(
            status: http.statusCode,
            endpoint: request.url?.path ?? "/v1/provider/account-earnings",
            baseURL: requestBaseURL(request)
        )
    }
    do {
        let report = try JSONDecoder().decode(ProviderAccountEarningsReport.self, from: data)
        guard !report.accountID.isEmpty else {
            throw EarningsFetchError.invalidResponse(
                endpoint: request.url?.path ?? "/v1/provider/account-earnings",
                baseURL: requestBaseURL(request)
            )
        }
        return report
    } catch let error as EarningsFetchError {
        throw error
    } catch {
        throw EarningsFetchError.invalidResponse(
            endpoint: request.url?.path ?? "/v1/provider/account-earnings",
            baseURL: requestBaseURL(request)
        )
    }
}

@discardableResult
func backfillProviderAccountID(
    _ accountID: String,
    existingAccountID: String? = ProviderAccountStore.load(),
    save: (String) throws -> Void = ProviderAccountStore.save
) -> Bool {
    guard !accountID.isEmpty, existingAccountID != accountID else { return false }
    do {
        try save(accountID)
        return true
    } catch {
        return false
    }
}

private func earningsResponse(
    request: URLRequest,
    transport: @escaping EarningsTransport
) async throws -> (Data, HTTPURLResponse) {
    let data: Data
    let response: URLResponse
    do {
        (data, response) = try await transport(request)
    } catch {
        throw EarningsFetchError.coordinatorUnreachable(
            baseURL: requestBaseURL(request),
            detail: error.localizedDescription
        )
    }
    guard let http = response as? HTTPURLResponse else {
        throw EarningsFetchError.invalidResponse(
            endpoint: request.url?.path ?? "earnings",
            baseURL: requestBaseURL(request)
        )
    }
    return (data, http)
}

private func requestBaseURL(_ request: URLRequest) -> String {
    guard let url = request.url else { return "coordinator" }
    var components = URLComponents()
    components.scheme = url.scheme
    components.host = url.host
    components.port = url.port
    return components.string ?? "coordinator"
}

private struct LegacyProviderEarningsReport: Decodable {
    struct Payout: Decodable {
        var id: Int64
        var providerAddress: String?
        var amountMicroUSD: Int64
        var model: String?
        var jobID: String?
        var timestamp: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case providerAddress = "provider_address"
            case amountMicroUSD = "amount_micro_usd"
            case model
            case jobID = "job_id"
            case timestamp
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(Int64.self, forKey: .id) ?? 0
            providerAddress = try container.decodeIfPresent(String.self, forKey: .providerAddress)
            amountMicroUSD = try container.decodeIfPresent(Int64.self, forKey: .amountMicroUSD) ?? 0
            model = try container.decodeIfPresent(String.self, forKey: .model)
            jobID = try container.decodeIfPresent(String.self, forKey: .jobID)
            timestamp = try container.decodeIfPresent(LegacyEarningsTimestamp.self, forKey: .timestamp)?.date
        }
    }

    var balanceMicroUSD: Int64
    var balanceUSD: String
    var totalEarnedMicroUSD: Int64
    var totalEarnedUSD: String
    var totalJobs: Int
    var payouts: [Payout]

    enum CodingKeys: String, CodingKey {
        case balanceMicroUSD = "balance_micro_usd"
        case balanceUSD = "balance_usd"
        case totalEarnedMicroUSD = "total_earned_micro_usd"
        case totalEarnedUSD = "total_earned_usd"
        case totalJobs = "total_jobs"
        case payouts
    }
}

private struct LegacyEarningsTimestamp: Decodable {
    let date: Date

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            self.date = date
            return
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = plain.date(from: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid RFC3339 timestamp")
            )
        }
        self.date = date
    }
}

func fetchLegacyWalletEarnings(
    request: URLRequest,
    wallet: String,
    transport: @escaping EarningsTransport
) async throws -> ProviderAccountEarningsReport {
    let (data, http) = try await earningsResponse(request: request, transport: transport)
    guard (200 ..< 300).contains(http.statusCode) else {
        throw EarningsFetchError.httpError(
            status: http.statusCode,
            endpoint: request.url?.path ?? "/v1/provider/earnings",
            baseURL: requestBaseURL(request)
        )
    }
    let legacy: LegacyProviderEarningsReport
    do {
        legacy = try JSONDecoder().decode(LegacyProviderEarningsReport.self, from: data)
    } catch {
        throw EarningsFetchError.invalidResponse(
            endpoint: request.url?.path ?? "/v1/provider/earnings",
            baseURL: requestBaseURL(request)
        )
    }
    let earnings = legacy.payouts.map { payout in
        let fallbackID = payout.id == 0 ? "legacy" : "legacy-\(payout.id)"
        return ProviderAccountEarningsReport.Earning(
            id: payout.id,
            accountID: wallet,
            providerID: payout.jobID ?? fallbackID,
            providerKey: payout.providerAddress ?? wallet,
            jobID: payout.jobID ?? "",
            model: payout.model ?? "",
            amountMicroUSD: payout.amountMicroUSD,
            promptTokens: 0,
            completionTokens: 0,
            createdAt: payout.timestamp
        )
    }
    return ProviderAccountEarningsReport(
        accountID: wallet,
        currentMachineID: macHardwareSerialNumber()
            .flatMap(ProviderMachineIdentity.id(serialNumber:)),
        earnings: earnings,
        totalMicroUSD: legacy.totalEarnedMicroUSD,
        totalUSD: legacy.totalEarnedUSD,
        count: Int64(max(0, legacy.totalJobs)),
        recentCount: earnings.count,
        historyLimit: earnings.count,
        availableBalanceMicroUSD: legacy.balanceMicroUSD,
        availableBalanceUSD: legacy.balanceUSD,
        withdrawableBalanceMicroUSD: legacy.balanceMicroUSD,
        withdrawableBalanceUSD: legacy.balanceUSD
    )
}

struct Earnings: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "earnings",
        abstract: "Show this provider's earnings from the coordinator.",
        discussion: """
        Reads the authenticated earnings history for the account linked via
        `darkbloom login`. Existing installations that predate the local
        provider-account file recover it from the authenticated response.
        Use --wallet only for legacy unlinked-wallet earnings.
        """
    )

    @OptionGroup var configOptions: ConfigOptions

    @Flag(name: .long, help: "Emit the earnings payload as JSON.")
    var json = false

    @Option(name: .long, help: "Legacy unlinked wallet/address override.")
    var wallet: String?

    mutating func run() async throws {
        let snapshot = try loadRuntimeSnapshot(
            configPath: configOptions.config,
            migrateOnDisk: false
        )
        let transport: EarningsTransport = { try await URLSession.shared.data(for: $0) }

        var report: ProviderAccountEarningsReport
        do {
            if let wallet, !wallet.isEmpty {
                let request = try makeLegacyWalletEarningsRequest(
                    coordinatorURL: snapshot.config.coordinator.url,
                    wallet: wallet
                )
                report = try await fetchLegacyWalletEarnings(
                    request: request,
                    wallet: wallet,
                    transport: transport
                )
            } else {
                guard let token = AuthTokenStore.load(), !token.isEmpty else {
                    printError("This Mac is not linked to a provider account. Run `darkbloom login` to link it.")
                    throw ExitCode.failure
                }
                let request = try makeAccountEarningsRequest(
                    coordinatorURL: snapshot.config.coordinator.url,
                    authToken: token
                )
                report = try await fetchAccountEarnings(
                    request: request,
                    transport: transport
                )
                _ = backfillProviderAccountID(report.accountID)
            }
        } catch let error as EarningsFetchError {
            printError(error.description)
            throw ExitCode.failure
        }

        report.currentProviderKey = DaemonStateFile.read()?.identity?.providerKey
        report.currentMachineID = macHardwareSerialNumber()
            .flatMap(ProviderMachineIdentity.id(serialNumber:))

        if json {
            try printJSON(report)
            return
        }

        print("Provider earnings (account: \(report.accountID))")
        print("  Available balance:    $\(report.availableBalanceUSD) (\(report.availableBalanceMicroUSD) µ$)")
        print("  Withdrawable balance: $\(report.withdrawableBalanceUSD) (\(report.withdrawableBalanceMicroUSD) µ$)")
        print("  Total earned:         $\(report.totalUSD) across \(report.count) jobs")
        if report.earnings.isEmpty {
            print("  No earning records yet.")
        } else {
            print("  Recent earnings: \(report.earnings.count) (see --json for details)")
        }
    }
}
