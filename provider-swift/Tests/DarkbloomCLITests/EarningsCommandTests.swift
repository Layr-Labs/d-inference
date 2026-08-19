import Foundation
import Testing
@testable import darkbloom

// `darkbloom earnings` request building, response decoding, and error
// mapping. The transport seam keeps the whole path hermetic — the endpoint
// URL, the coordinator wallet query, and the coordinator's exact JSON shape
// are all pinned without a live socket.
@Suite("darkbloom earnings")
struct EarningsCommandTests {

    // MARK: Request building

    @Test("request URL derives the HTTP base from the configured ws coordinator URL")
    func requestBuilding() throws {
        let request = try makeEarningsRequest(
            coordinatorURL: "wss://api.darkbloom.dev/ws/provider",
            wallet: "acct-abc 1/2")
        let url = try #require(request.url)
        #expect(url.scheme == "https")
        #expect(url.host == "api.darkbloom.dev")
        #expect(url.path == "/v1/provider/earnings")
        // URLComponents legally preserves "/" in queries; " " must encode.
        #expect(url.query == "wallet=acct-abc%201/2")

        let local = try makeEarningsRequest(
            coordinatorURL: "ws://localhost:8080/ws/provider",
            wallet: "acct-x")
        #expect(local.url?.scheme == "http")
        #expect(local.url?.host == "localhost")
        #expect(local.url?.port == 8080)
    }

    @Test("unusable coordinator URLs throw instead of building a junk request")
    func requestRejectsBadBase() {
        #expect(throws: (any Error).self) {
            try makeEarningsRequest(coordinatorURL: "not a url", wallet: "acct")
        }
    }

    // MARK: Response decoding

    private let coordinatorJSON = """
    {
      "balance_micro_usd": 1350000,
      "balance_usd": "1.350000",
      "total_earned_micro_usd": 2250000,
      "total_earned_usd": "2.250000",
      "total_jobs": 3,
      "payouts": [
        {
          "id": 42,
          "provider_address": "acct-1",
          "amount_micro_usd": 900000,
          "model": "qwen3.5-9b",
          "job_id": "job-2",
          "timestamp": "2026-08-17T22:04:31.123456789Z",
          "settled": false
        },
        {
          "id": 0,
          "provider_address": "acct-1",
          "amount_micro_usd": 450000,
          "job_id": "job-1",
          "timestamp": "2026-08-16T10:00:00Z",
          "settled": true
        }
      ],
      "ledger": null
    }
    """

    @Test("coordinator payload decodes with tolerant timestamps and null ledger")
    func decodeCoordinatorShape() async throws {
        let request = try makeEarningsRequest(
            coordinatorURL: "wss://api.darkbloom.dev/ws/provider",
            wallet: "acct-1")
        let stub: EarningsTransport = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(coordinatorJSON.utf8), response)
        }
        let report = try await fetchProviderEarnings(request: request, transport: stub)

        #expect(report.balanceMicroUSD == 1_350_000)
        #expect(report.balanceUSD == "1.350000")
        #expect(report.totalEarnedMicroUSD == 2_250_000)
        #expect(report.totalJobs == 3)
        #expect(report.ledger == [], "JSON null ledger decodes as empty")
        #expect(report.payouts.count == 2)
        #expect(report.payouts[0].model == "qwen3.5-9b")
        #expect(report.payouts[0].settled == false)
        #expect(report.payouts[0].timestamp != nil, "RFC3339Nano decodes")
        #expect(report.payouts[1].model == nil, "ledger-reconstructed rows carry no model")
        #expect(report.payouts[1].timestamp != nil, "second-granularity RFC3339 also decodes")
        #expect(report.wallet == nil, "bare coordinator payload; the CLI stamps the echo")
    }

    @Test("ledger rows carry RFC3339 created_at both directions")
    func ledgerTimestamps() async throws {
        let json = """
        {
          "balance_micro_usd": 100000,
          "balance_usd": "0.100000",
          "total_earned_micro_usd": 100000,
          "total_earned_usd": "0.100000",
          "total_jobs": 1,
          "payouts": [],
          "ledger": [
            {
              "id": 9,
              "account_id": "acct-1",
              "type": "payout",
              "amount_micro_usd": 100000,
              "balance_after": 100000,
              "reference": "job-9",
              "created_at": "2026-08-17T22:04:31.123456789Z"
            }
          ]
        }
        """
        let request = try makeEarningsRequest(
            coordinatorURL: "wss://api.darkbloom.dev/ws/provider",
            wallet: "acct-1")
        let stub: EarningsTransport = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), response)
        }
        let report = try await fetchProviderEarnings(request: request, transport: stub)
        let entry = try #require(report.ledger.first)
        #expect(entry.type == "payout")
        #expect(entry.createdAt != nil)

        // The CLI's --json re-encode must itself be decodable (RFC3339
        // strings, never numeric timestamps) for the app's decoder.
        let reencoded = try JSONEncoder().encode(report)
        let raw = String(decoding: reencoded, as: UTF8.self)
        #expect(raw.contains("\"created_at\":\"2026-08-17T22:04:31"))
        #expect(!raw.contains("\"created_at\":1."))
        let roundTrip = try JSONDecoder().decode(ProviderEarningsReport.self, from: reencoded)
        #expect(roundTrip.ledger == report.ledger)
    }

    @Test("the CLI stamps the requested wallet onto the decoded report")
    func walletEcho() async throws {
        let request = try makeEarningsRequest(
            coordinatorURL: "wss://api.darkbloom.dev/ws/provider",
            wallet: "acct-1")
        let stub: EarningsTransport = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(coordinatorJSON.utf8), response)
        }
        var report = try await fetchProviderEarnings(request: request, transport: stub)
        report.wallet = "acct-1"
        let data = try JSONEncoder().encode(report)
        let roundTrip = try JSONDecoder().decode(ProviderEarningsReport.self, from: data)
        #expect(roundTrip.wallet == "acct-1")
        #expect(roundTrip == report)
    }

    // MARK: Error mapping

    @Test("a dead coordinator maps to coordinatorUnreachable with one-line guidance")
    func unreachableMaps() async throws {
        let request = try makeEarningsRequest(
            coordinatorURL: "ws://localhost:9/ws/provider", wallet: "acct")
        let stub: EarningsTransport = { _ in
            struct Offline: Error, LocalizedError {
                var errorDescription: String? { "Connection refused" }
            }
            throw Offline()
        }
        do {
            _ = try await fetchProviderEarnings(request: request, transport: stub)
            Issue.record("expected coordinatorUnreachable")
        } catch let error as EarningsFetchError {
            guard case .coordinatorUnreachable(let baseURL, let detail) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(baseURL.contains("localhost"))
            #expect(detail.contains("Connection refused"))
            #expect(error.description.contains("Check your connection"))
        }
    }

    @Test("non-2xx maps to httpError carrying the status")
    func httpErrorMaps() async throws {
        let request = try makeEarningsRequest(
            coordinatorURL: "wss://api.darkbloom.dev/ws/provider", wallet: "acct")
        let stub: EarningsTransport = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 502, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
        do {
            _ = try await fetchProviderEarnings(request: request, transport: stub)
            Issue.record("expected httpError")
        } catch let error as EarningsFetchError {
            guard case .httpError(let status, _) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(status == 502)
        }
    }

    @Test("malformed JSON maps to invalidResponse")
    func invalidResponseMaps() async throws {
        let request = try makeEarningsRequest(
            coordinatorURL: "wss://api.darkbloom.dev/ws/provider", wallet: "acct")
        let stub: EarningsTransport = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("<html>oops</html>".utf8), response)
        }
        do {
            _ = try await fetchProviderEarnings(request: request, transport: stub)
            Issue.record("expected invalidResponse")
        } catch let error as EarningsFetchError {
            #expect(error == error) // Equatable
            guard case .invalidResponse = error else {
                Issue.record("wrong error: \(error)")
                return
            }
        }
    }
}
