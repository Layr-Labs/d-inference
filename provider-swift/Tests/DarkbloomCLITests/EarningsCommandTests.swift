import Foundation
import Testing
@testable import darkbloom
import ProviderCoreFoundation

@Suite("darkbloom earnings")
struct EarningsCommandTests {
    private let accountJSON = """
    {
      "account_id": "acct-1",
      "available_balance_micro_usd": 1350000,
      "available_balance_usd": "1.350000",
      "withdrawable_balance_micro_usd": 1100000,
      "withdrawable_balance_usd": "1.100000",
      "total_micro_usd": 2250000,
      "total_usd": "2.250000",
      "count": 3,
      "recent_count": 2,
      "history_limit": 1000,
      "providers": [
        {
          "provider_id": "session-1",
          "provider_key": "key-1",
          "machine_id": "machine-1"
        }
      ],
      "earnings": [
        {
          "id": 42,
          "account_id": "acct-1",
          "provider_id": "session-1",
          "provider_key": "key-1",
          "amount_micro_usd": 900000,
          "model": "qwen3.5-9b",
          "job_id": "job-2",
          "prompt_tokens": 120,
          "completion_tokens": 45,
          "created_at": "2026-08-17T22:04:31.123456789Z"
        },
        {
          "id": 43,
          "account_id": "acct-1",
          "provider_id": "",
          "provider_key": "key-1",
          "amount_micro_usd": 450000,
          "model": "base_reward",
          "job_id": "floor:2026-08:key-1",
          "prompt_tokens": 0,
          "completion_tokens": 0,
          "created_at": "2026-08-16T10:00:00Z"
        }
      ]
    }
    """

    @Test("linked request uses provider-token auth and the account endpoint")
    func linkedRequest() throws {
        let request = try makeAccountEarningsRequest(
            coordinatorURL: "wss://api.darkbloom.dev/ws/provider",
            authToken: "provider-token"
        )
        let url = try #require(request.url)
        #expect(url.scheme == "https")
        #expect(url.host == "api.darkbloom.dev")
        #expect(url.path == "/v1/provider/account-earnings")
        #expect(url.query == "limit=1000")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer provider-token")

        let local = try makeAccountEarningsRequest(
            coordinatorURL: "ws://localhost:8080/ws/provider",
            authToken: "token",
            limit: 50
        )
        #expect(local.url?.scheme == "http")
        #expect(local.url?.port == 8080)
        #expect(local.url?.query == "limit=50")
    }

    @Test("legacy wallet override remains isolated on the unauthenticated endpoint")
    func legacyRequest() throws {
        let request = try makeLegacyWalletEarningsRequest(
            coordinatorURL: "wss://api.darkbloom.dev/ws/provider",
            wallet: "wallet 1/2"
        )
        #expect(request.url?.path == "/v1/provider/earnings")
        #expect(request.url?.query == "wallet=wallet%201/2")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("unusable coordinator URLs and empty tokens are rejected")
    func requestValidation() {
        #expect(throws: (any Error).self) {
            try makeAccountEarningsRequest(
                coordinatorURL: "not a url",
                authToken: "token"
            )
        }
        #expect(throws: (any Error).self) {
            try makeAccountEarningsRequest(
                coordinatorURL: "wss://api.darkbloom.dev/ws/provider",
                authToken: ""
            )
        }
    }

    @Test("linked response preserves tokens, base rewards, identities, and timestamps")
    func decodeAccountShape() async throws {
        let request = try makeAccountEarningsRequest(
            coordinatorURL: "wss://api.darkbloom.dev/ws/provider",
            authToken: "token"
        )
        let report = try await fetchAccountEarnings(
            request: request,
            transport: response(status: 200, body: accountJSON)
        )

        #expect(report.accountID == "acct-1")
        #expect(report.availableBalanceMicroUSD == 1_350_000)
        #expect(report.withdrawableBalanceMicroUSD == 1_100_000)
        #expect(report.totalMicroUSD == 2_250_000)
        #expect(report.count == 3)
        #expect(report.earnings.count == 2)
        #expect(report.earnings[0].promptTokens == 120)
        #expect(report.earnings[0].completionTokens == 45)
        #expect(report.earnings[0].createdAt != nil)
        #expect(report.earnings[1].model == "base_reward")
        #expect(report.earnings[1].createdAt != nil)
        #expect(report.providers == [
            .init(
                providerID: "session-1",
                providerKey: "key-1",
                machineID: "machine-1"
            ),
        ])

        let reencoded = try JSONEncoder().encode(report)
        let raw = String(decoding: reencoded, as: UTF8.self)
        #expect(raw.contains("\"created_at\":\"2026-08-17T22:04:31"))
        #expect(!raw.contains("\"created_at\":1."))
        let roundTrip = try JSONDecoder().decode(
            ProviderAccountEarningsReport.self,
            from: reencoded
        )
        #expect(roundTrip == report)
    }

    @Test("authenticated account id backfills missing and stale local identity")
    func accountIDBackfill() {
        var saved: [String] = []
        #expect(backfillProviderAccountID(
            "acct-server",
            existingAccountID: nil,
            save: { saved.append($0) }
        ))
        #expect(saved == ["acct-server"])

        #expect(!backfillProviderAccountID(
            "acct-server",
            existingAccountID: "acct-server",
            save: { saved.append($0) }
        ))
        #expect(saved == ["acct-server"])

        #expect(backfillProviderAccountID(
            "acct-new",
            existingAccountID: "acct-stale",
            save: { saved.append($0) }
        ))
        #expect(saved == ["acct-server", "acct-new"])
    }

    @Test("legacy wallet rows adapt to the unified CLI JSON contract")
    func legacyAdapter() async throws {
        let request = try makeLegacyWalletEarningsRequest(
            coordinatorURL: "wss://api.darkbloom.dev/ws/provider",
            wallet: "wallet-1"
        )
        let json = """
        {
          "balance_micro_usd": 100000,
          "balance_usd": "0.100000",
          "total_earned_micro_usd": 100000,
          "total_earned_usd": "0.100000",
          "total_jobs": 1,
          "payouts": [{
            "id": 9,
            "provider_address": "wallet-1",
            "amount_micro_usd": 100000,
            "model": "legacy-model",
            "job_id": "legacy-job",
            "timestamp": "2026-08-17T22:04:31.123456789Z"
          }],
          "ledger": null
        }
        """
        let report = try await fetchLegacyWalletEarnings(
            request: request,
            wallet: "wallet-1",
            transport: response(status: 200, body: json)
        )

        #expect(report.accountID == "wallet-1")
        #expect(report.availableBalanceMicroUSD == 100_000)
        #expect(report.withdrawableBalanceMicroUSD == 100_000)
        #expect(report.earnings[0].providerKey == "wallet-1")
        #expect(report.earnings[0].promptTokens == 0)
    }

    @Test("a dead coordinator maps to connection guidance without relogin advice")
    func unreachableMaps() async throws {
        let request = try makeAccountEarningsRequest(
            coordinatorURL: "ws://localhost:9/ws/provider",
            authToken: "token"
        )
        let transport: EarningsTransport = { _ in
            struct Offline: Error, LocalizedError {
                var errorDescription: String? { "Connection refused" }
            }
            throw Offline()
        }
        do {
            _ = try await fetchAccountEarnings(request: request, transport: transport)
            Issue.record("expected coordinatorUnreachable")
        } catch let error as EarningsFetchError {
            guard case .coordinatorUnreachable(let baseURL, let detail) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(baseURL.contains("localhost"))
            #expect(detail.contains("Connection refused"))
            #expect(error.description.contains("Check your connection"))
            #expect(!error.description.contains("darkbloom login"))
        }
    }

    @Test("revoked provider tokens produce explicit relink guidance")
    func authenticationError() async throws {
        let request = try makeAccountEarningsRequest(
            coordinatorURL: "wss://api.darkbloom.dev/ws/provider",
            authToken: "revoked"
        )
        await #expect(throws: EarningsFetchError.authenticationRejected(status: 401)) {
            try await fetchAccountEarnings(
                request: request,
                transport: response(status: 401, body: "{}")
            )
        }
        #expect(
            EarningsFetchError.authenticationRejected(status: 401)
                .description.contains("darkbloom logout")
        )
    }

    @Test("malformed JSON maps to the account endpoint in its error")
    func invalidResponseMaps() async throws {
        let request = try makeAccountEarningsRequest(
            coordinatorURL: "wss://api.darkbloom.dev/ws/provider",
            authToken: "token"
        )
        do {
            _ = try await fetchAccountEarnings(
                request: request,
                transport: response(status: 200, body: "<html>oops</html>")
            )
            Issue.record("expected invalidResponse")
        } catch let error as EarningsFetchError {
            guard case .invalidResponse(let endpoint, _) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(endpoint == "/v1/provider/account-earnings")
        }
    }

    private func response(
        status: Int,
        body: String
    ) -> EarningsTransport {
        { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(body.utf8), response)
        }
    }
}
