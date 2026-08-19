import Foundation
import Testing
@testable import DarkbloomApp

// Golden-JSON tests for the My Macs coordinator client. Field names and
// optionality are pinned to coordinator/api/me_handlers.go
// (handleMyProviders / handleMySummary / handleDeleteMyProvider) and the
// requirePrivyAuth middleware in coordinator/api/server.go.
@Suite("FleetClient requests and decodes the account-scoped coordinator endpoints")
struct FleetClientTests {
    // MARK: Stubs + fixture payloads

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URLRequest] = []
        var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func record(_ request: URLRequest) {
            lock.lock()
            stored.append(request)
            lock.unlock()
        }
    }

    /// Representative /v1/me/providers body: one live serving machine, one
    /// retained offline machine — pinned to `myProvider` /
    /// `myProvidersResponse` JSON tags.
    static let providersGoldenJSON = #"""
    {
      "providers": [
        {
          "id": "session-live-1",
          "account_id": "acct-1",
          "status": "serving",
          "online": true,
          "last_heartbeat": "2026-08-18T12:34:56.789Z",
          "hardware": {
            "machine_model": "MacBook Pro",
            "chip_name": "Apple M4 Max",
            "memory_gb": 64,
            "memory_available_gb": 41.5,
            "cpu_cores": {"total": 16, "performance": 12, "efficiency": 4},
            "gpu_cores": 40,
            "memory_bandwidth_gbs": 546.0
          },
          "models": [
            {
              "id": "gpt-oss-20b",
              "size_bytes": 12884901888,
              "model_type": "text",
              "quantization": "4-bit",
              "weight_hash": "4f1c9c7a",
              "is_vision": false,
              "template_render_ok": true
            }
          ],
          "backend": "mlx-swift",
          "version": "0.8.1",
          "serial_number": "FVFGH0STQ6L4",
          "trust_level": "hardware",
          "attested": true,
          "mda_verified": true,
          "acme_verified": false,
          "se_key_bound": true,
          "se_public_key": "se-pubkey-b64",
          "provider_key": "x25519-live-pub",
          "secure_enclave": true,
          "sip_enabled": true,
          "secure_boot_enabled": true,
          "authenticated_root_enabled": true,
          "runtime_verified": true,
          "last_challenge_verified": "2026-08-18T12:30:00Z",
          "failed_challenges": 0,
          "system_metrics": {"memory_pressure": 0.3, "cpu_usage": 0.42, "thermal_state": "nominal"},
          "backend_capacity": {
            "slots": [
              {
                "model": "gpt-oss-20b",
                "state": "running",
                "num_running": 2,
                "num_waiting": 1,
                "max_concurrency": 4,
                "active_tokens": 3840,
                "max_tokens_potential": 8192,
                "observed_decode_tps": 51.5,
                "observed_prefill_tps": 248.5,
                "active_token_budget_used": 8192,
                "active_token_budget_max": 32768,
                "queued_token_budget": 1024,
                "model_load_time_ms": 8420
              }
            ],
            "gpu_memory_active_gb": 22.4,
            "gpu_memory_peak_gb": 28.8,
            "gpu_memory_cache_gb": 3.1,
            "total_memory_gb": 64.0,
            "free_for_load_gb": 18.2
          },
          "warm_models": ["gpt-oss-20b"],
          "current_model": "gpt-oss-20b",
          "pending_requests": 2,
          "max_concurrency": 4,
          "prefill_tps": 248.5,
          "decode_tps": 51.5,
          "reputation": {
            "score": 0.97,
            "total_jobs": 214,
            "successful_jobs": 210,
            "failed_jobs": 4,
            "total_uptime_seconds": 604800,
            "avg_response_time_ms": 420,
            "challenges_passed": 1044,
            "challenges_failed": 0
          },
          "lifetime_requests_served": 214,
          "lifetime_tokens_generated": 1482304,
          "registered_at": "2026-07-19T12:34:56Z",
          "last_seen": "2026-08-18T12:34:56Z"
        },
        {
          "id": "session-retained-2",
          "account_id": "acct-1",
          "status": "offline",
          "online": false,
          "hardware": {"machine_model": "Mac mini", "chip_name": "Apple M4 Pro", "memory_gb": 48, "gpu_cores": 20},
          "models": [],
          "backend": "mlx-swift",
          "version": "0.8.0",
          "serial_number": "C07QMINI2025",
          "trust_level": "hardware",
          "attested": true,
          "mda_verified": true,
          "acme_verified": false,
          "se_key_bound": true,
          "se_public_key": "se-other-b64",
          "provider_key": "x25519-persisted-pub",
          "secure_enclave": true,
          "sip_enabled": true,
          "secure_boot_enabled": true,
          "authenticated_root_enabled": true,
          "runtime_verified": true,
          "failed_challenges": 0,
          "pending_requests": 0,
          "max_concurrency": 0,
          "prefill_tps": 0,
          "decode_tps": 0,
          "reputation": {
            "score": 0,
            "total_jobs": 0,
            "successful_jobs": 0,
            "failed_jobs": 0,
            "total_uptime_seconds": 0,
            "avg_response_time_ms": 0,
            "challenges_passed": 0,
            "challenges_failed": 0
          },
          "lifetime_requests_served": 12,
          "lifetime_tokens_generated": 34567,
          "registered_at": "2026-08-10T09:00:00Z",
          "last_seen": "2026-08-17T09:00:00Z"
        }
      ],
      "latest_provider_version": "0.8.1",
      "min_provider_version": "0.7.5",
      "heartbeat_timeout_seconds": 90,
      "challenge_max_age_seconds": 360
    }
    """#

    /// Representative /v1/me/summary body — pinned to `mySummaryResponse` /
    /// `myFleetCounts` JSON tags.
    static let summaryGoldenJSON = #"""
    {
      "account_id": "acct-1",
      "available_balance_micro_usd": 12850000,
      "withdrawable_balance_micro_usd": 10500000,
      "payout_ready": true,
      "lifetime_micro_usd": 31740000,
      "lifetime_jobs": 428,
      "last_24h_micro_usd": 1460000,
      "last_24h_jobs": 18,
      "last_7d_micro_usd": 8920000,
      "last_7d_jobs": 104,
      "counts": {
        "total": 2,
        "online": 0,
        "serving": 1,
        "offline": 1,
        "untrusted": 0,
        "hardware": 2,
        "needs_attention": 1
      },
      "latest_provider_version": "0.8.1",
      "min_provider_version": "0.7.5"
    }
    """#

    static let conflictJSON = #"""
    {"error": {"type": "conflict", "message": "machine is currently online — stop it before removing", "code": "conflict"}}
    """#

    private func makeClient(
        recorder: Recorder,
        statusCode: Int,
        body: String
    ) -> FleetClient {
        FleetClient(baseURL: FleetClient.defaultCoordinatorBaseURL) { request in
            recorder.record(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (Data(body.utf8), response)
        }
    }

    // MARK: GET /v1/me/providers

    @Test("Fetches the account fleet with the Privy bearer token")
    func providersFetchDecodesGoldenPayload() async throws {
        let recorder = Recorder()
        let client = makeClient(recorder: recorder, statusCode: 200, body: Self.providersGoldenJSON)

        let response = try await client.providers(bearerToken: "privy-jwt-1")

        let request = try #require(recorder.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.darkbloom.dev/v1/me/providers")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer privy-jwt-1")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")

        #expect(response.providers.count == 2)
        #expect(response.latestProviderVersion == "0.8.1")
        #expect(response.minimumProviderVersion == "0.7.5")
        #expect(response.heartbeatTimeoutSeconds == 90)
        #expect(response.challengeMaxAgeSeconds == 360)

        let live = response.providers[0]
        #expect(live.providerID == "session-live-1")
        #expect(live.status == "serving")
        #expect(live.online == true)
        #expect(live.serialNumber == "FVFGH0STQ6L4")
        #expect(live.providerKey == "x25519-live-pub")
        #expect(live.trustLevel == "hardware")
        #expect(live.hardware?.memoryAvailableGB == 41.5)
        #expect(live.hardware?.cpuCores?.performance == 12)
        #expect(live.models?.first?.isVision == false)
        #expect(live.backendCapacity?.slots.first?.state == "running")
        #expect(live.backendCapacity?.slots.first?.queuedTokenBudget == 1024)
        #expect(live.backendCapacity?.freeForLoadGB == 18.2)
        #expect(live.reputation?.averageResponseTimeMS == 420)
        #expect(live.lastHeartbeat != nil)
        #expect(live.lastChallengeVerified != nil)
        // Go RFC3339Nano fractional seconds must decode, not be dropped.
        let heartbeat = try #require(live.lastHeartbeat)
        #expect(abs(heartbeat.timeIntervalSince1970 - 1_787_056_496.789) < 0.001)

        let offline = response.providers[1]
        #expect(offline.status == "offline")
        #expect(offline.online == false)
        #expect(offline.models == [])
        #expect(offline.providerKey == "x25519-persisted-pub")
        #expect(offline.lastHeartbeat == nil)
    }

    @Test("Decoded providers payload maps into the My Macs domain snapshot")
    func providersPayloadMapsToDomainSnapshot() throws {
        let decoder = MyMacsWireDecoder()
        let wire = try decoder.decodeProviders(from: Data(Self.providersGoldenJSON.utf8))
        let asOf = Date(timeIntervalSince1970: 1_787_057_000)
        let snapshot = try MyMacsSnapshot(providers: wire, summary: nil, asOf: asOf)

        #expect(snapshot.macs.count == 2)
        #expect(snapshot.context.heartbeatTimeoutSeconds == 90)
        let serving = try #require(snapshot.macs.first { $0.lifecycle == .serving })
        #expect(serving.removalToken == nil) // live machines are not removable
        let offline = try #require(snapshot.macs.first { $0.lifecycle == .offline })
        #expect(offline.removalToken == "C07QMINI2025")
    }

    // MARK: GET /v1/me/summary

    @Test("Fetches the account summary header with coordinator counts untouched")
    func summaryFetchDecodesGoldenPayload() async throws {
        let recorder = Recorder()
        let client = makeClient(recorder: recorder, statusCode: 200, body: Self.summaryGoldenJSON)

        let response = try await client.summary(bearerToken: "privy-jwt-2")

        let request = try #require(recorder.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.darkbloom.dev/v1/me/summary")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer privy-jwt-2")

        #expect(response.accountID == "acct-1")
        #expect(response.availableBalanceMicroUSD == 12_850_000)
        #expect(response.withdrawableBalanceMicroUSD == 10_500_000)
        #expect(response.payoutReady)
        #expect(response.lifetimeMicroUSD == 31_740_000)
        #expect(response.last24hJobs == 18)
        #expect(response.last7dJobs == 104)
        #expect(response.counts.serving == 1)
        #expect(response.counts.offline == 1)
        #expect(response.counts.needsAttention == 1)
        #expect(response.minimumProviderVersion == "0.7.5")
    }

    // MARK: DELETE /v1/me/providers/{serial}

    @Test("Removal sends DELETE to the serial path token")
    func deleteUsesCoordinatorSerialPath() async throws {
        let recorder = Recorder()
        let client = makeClient(recorder: recorder, statusCode: 200, body: #"{"deleted": true}"#)

        try await client.deleteProvider(removalToken: "C07QMINI2025", bearerToken: "privy-jwt-3")

        let request = try #require(recorder.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.absoluteString == "https://api.darkbloom.dev/v1/me/providers/C07QMINI2025")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer privy-jwt-3")
    }

    @Test("Removal surfaces the coordinator conflict detail for online machines")
    func deleteConflictPreservesCoordinatorMessage() async throws {
        let client = makeClient(recorder: Recorder(), statusCode: 409, body: Self.conflictJSON)

        do {
            try await client.deleteProvider(removalToken: "FVFGH0STQ6L4", bearerToken: "token")
            Issue.record("A 409 must throw, not look like a deletion")
        } catch FleetClientError.httpError(let statusCode, let detail) {
            #expect(statusCode == 409)
            #expect(detail == "machine is currently online — stop it before removing")
        } catch {
            Issue.record("Expected a typed httpError, got \(error)")
        }
    }

    // MARK: Status/error mapping

    @Test("HTTP 401 maps to the session-expired signal on every endpoint")
    func unauthorizedMapsToSessionExpired() async throws {
        let body = #"{"error": {"type": "authentication_error", "message": "invalid Privy token"}}"#
        let calls: [(FleetClient) async throws -> Void] = [
            { _ = try await $0.providers(bearerToken: "expired") },
            { _ = try await $0.summary(bearerToken: "expired") },
            { try await $0.deleteProvider(removalToken: "S", bearerToken: "expired") },
        ]
        for call in calls {
            let client = makeClient(recorder: Recorder(), statusCode: 401, body: body)
            do {
                try await call(client)
                Issue.record("A 401 must throw the session-expired signal")
            } catch FleetClientError.sessionExpired {
                // expected
            } catch {
                Issue.record("Expected sessionExpired, got \(error)")
            }
        }
    }

    @Test("Transport failures and non-HTTP responses are unreachable, not expiry")
    func transportFailuresAreUnreachable() async throws {
        let failing = FleetClient(baseURL: FleetClient.defaultCoordinatorBaseURL) { _ in
            throw URLError(.notConnectedToInternet)
        }
        do {
            _ = try await failing.providers(bearerToken: "token")
            Issue.record("Transport failure must throw")
        } catch FleetClientError.unreachable {
            // expected — must NOT surface as sessionExpired (no sign-out churn
            // for transient connectivity loss)
        } catch {
            Issue.record("Expected unreachable, got \(error)")
        }
    }

    @Test("A malformed payload surfaces a decoding failure")
    func malformedPayloadThrows() async throws {
        let client = makeClient(recorder: Recorder(), statusCode: 200, body: #"{"unexpected": true}"#)
        await #expect(throws: (any Error).self) {
            _ = try await client.providers(bearerToken: "token")
        }
    }

    // MARK: Base URL configuration

    @Test("Coordinator base URL defaults to prod and honors the env override")
    func baseURLResolution() {
        #expect(FleetClient.resolveBaseURL(environment: [:]) == FleetClient.defaultCoordinatorBaseURL)
        #expect(
            FleetClient.resolveBaseURL(
                environment: ["DARKBLOOM_COORDINATOR_URL": "https://api.dev.darkbloom.xyz"]
            ) == URL(string: "https://api.dev.darkbloom.xyz")
        )
        // Garbage or empty overrides must not wedge request building.
        #expect(
            FleetClient.resolveBaseURL(
                environment: ["DARKBLOOM_COORDINATOR_URL": "  not a url  "]
            ) == FleetClient.defaultCoordinatorBaseURL
        )
        #expect(
            FleetClient.resolveBaseURL(
                environment: ["DARKBLOOM_COORDINATOR_URL": "ftp://nope"]
            ) == FleetClient.defaultCoordinatorBaseURL
        )
    }
}
