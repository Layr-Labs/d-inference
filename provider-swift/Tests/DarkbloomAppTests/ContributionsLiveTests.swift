import Foundation
import Testing
@testable import DarkbloomApp

@Suite("ContributionsStore live mode")
struct ContributionsLiveTests {
    actor StubCLI: ContributionsCLIRunning {
        nonisolated(unsafe) var payload: ContributionsEarningsPayload?
        nonisolated(unsafe) var error: (any Error)?
        private(set) var fetchCount = 0

        func fetchEarnings() async throws -> ContributionsEarningsPayload {
            fetchCount += 1
            if let error {
                throw error
            }
            guard let payload else {
                throw ContributionsCLIError.invalidOutput("stub has no payload")
            }
            return payload
        }
    }

    private let currentSerial = "CURRENT-SERIAL"
    private let currentKey = "key-current"
    private let priorCurrentKey = "key-current-prior"
    private let otherKey = "key-other"

    private var providers: [ContributionsEarningsPayload.ProviderIdentity] {
        [
            .init(
                providerID: "session-current",
                providerKey: currentKey,
                serialNumber: currentSerial
            ),
            .init(
                providerID: "session-current-prior",
                providerKey: priorCurrentKey,
                serialNumber: currentSerial
            ),
            .init(
                providerID: "session-other",
                providerKey: otherKey,
                serialNumber: "OTHER-SERIAL-9876"
            ),
        ]
    }

    private var sampleEarnings: [ContributionsEarningsPayload.Earning] {
        [
            .init(
                id: 42,
                accountID: "acct-live-1",
                providerID: "session-current",
                providerKey: currentKey,
                jobID: "job-2",
                model: "qwen3.5-9b",
                amountMicroUSD: 900_000,
                promptTokens: 120,
                completionTokens: 45,
                createdAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            .init(
                id: 43,
                accountID: "acct-live-1",
                providerID: "",
                providerKey: priorCurrentKey,
                jobID: "floor:2026-08:key-current-prior",
                model: "base_reward",
                amountMicroUSD: 450_000,
                promptTokens: 0,
                completionTokens: 0,
                createdAt: Date(timeIntervalSince1970: 1_799_000_000)
            ),
            .init(
                id: 44,
                accountID: "acct-live-1",
                providerID: "session-other",
                providerKey: otherKey,
                jobID: "job-other",
                model: "gemma-4-26b",
                amountMicroUSD: 300_000,
                promptTokens: 80,
                completionTokens: 20,
                createdAt: Date(timeIntervalSince1970: 1_798_000_000)
            ),
        ]
    }

    private func payload(
        currentProviderKey: String? = nil,
        currentSerialNumber: String? = "CURRENT-SERIAL",
        available: Int64 = 1_350_000,
        withdrawable: Int64 = 1_100_000,
        earned: Int64 = 2_250_000,
        jobs: Int64 = 2,
        earnings: [ContributionsEarningsPayload.Earning]? = nil,
        providers: [ContributionsEarningsPayload.ProviderIdentity]? = nil
    ) -> ContributionsEarningsPayload {
        ContributionsEarningsPayload(
            accountID: "acct-live-1",
            currentProviderKey: currentProviderKey,
            currentSerialNumber: currentSerialNumber,
            earnings: earnings ?? sampleEarnings,
            providers: providers ?? self.providers,
            totalMicroUSD: earned,
            totalUSD: "2.250000",
            count: jobs,
            recentCount: (earnings ?? sampleEarnings).count,
            historyLimit: 1_000,
            availableBalanceMicroUSD: available,
            availableBalanceUSD: "1.350000",
            withdrawableBalanceMicroUSD: withdrawable,
            withdrawableBalanceUSD: "1.100000"
        )
    }

    @Test("live refresh maps authenticated balances and every key for this Mac")
    @MainActor
    func refreshMapsPayload() async throws {
        let cli = StubCLI()
        cli.payload = payload(currentProviderKey: currentKey)
        let store = ContributionsStore(
            cli: cli,
            now: { Date(timeIntervalSince1970: 1_800_001_000) }
        )

        #expect(store.availability == .loading)
        await store.refresh()

        guard case .available = store.availability else {
            Issue.record("expected available, got \(store.availability)")
            return
        }
        let snapshot = try #require(store.snapshot)
        #expect(snapshot.currentProviderKeys == [currentKey, priorCurrentKey])
        #expect(snapshot.availableBalance == MicroUSD(1_350_000))
        #expect(snapshot.withdrawableBalance == MicroUSD(1_100_000))
        #expect(snapshot.earnedLifetime == MicroUSD(2_250_000))
        #expect(snapshot.lifetimeJobs == 2)
        #expect(snapshot.minimumPayout == ContributionsLiveMapping.liveMinimumPayout)
        #expect(snapshot.payoutReadiness == .ready)
        #expect(store.pulsePreview == nil)
    }

    @Test("earning rows preserve model, tokens, node identity, and base rewards")
    @MainActor
    func recordsMapping() async throws {
        let cli = StubCLI()
        cli.payload = payload()
        let store = ContributionsStore(
            cli: cli,
            now: { Date(timeIntervalSince1970: 1_800_001_000) }
        )
        await store.refresh()

        let records = try #require(store.snapshot?.records)
        #expect(records.count == 3)

        let inference = try #require(records.first { $0.id == "earning-42" })
        #expect(inference.modelID == "qwen3.5-9b")
        #expect(inference.providerKey == currentKey)
        #expect(inference.providerID == "session-current")
        #expect(inference.providerName == "This Mac")
        #expect(inference.inputTokens == 120)
        #expect(inference.outputTokens == 45)
        #expect(inference.amount == MicroUSD(900_000))

        let baseReward = try #require(records.first { $0.id == "earning-43" })
        #expect(baseReward.modelID == "base_reward")
        #expect(baseReward.modelName == "Base reward")
        #expect(baseReward.providerKey == priorCurrentKey)
        #expect(baseReward.providerID == priorCurrentKey)
        #expect(baseReward.totalTokens == 0)

        let other = try #require(records.first { $0.id == "earning-44" })
        #expect(other.providerName == "Mac ••••9876")
        #expect(Set(records.map(\.id)).count == records.count)
    }

    @Test("this-Mac scope includes prior daemon keys but excludes other Macs")
    @MainActor
    func scopeFiltering() async throws {
        let cli = StubCLI()
        cli.payload = payload()
        let store = ContributionsStore(
            cli: cli,
            now: { Date(timeIntervalSince1970: 1_800_001_000) }
        )
        await store.refresh()

        #expect(Set(store.filteredLedger.map(\.providerKey)) == [currentKey, priorCurrentKey])
        #expect(store.shownRecordsTokenCount == 165)
        store.setScope(.allMacs)
        #expect(store.filteredLedger.count == 3)
        #expect(store.shownRecordsTokenCount == 265)
    }

    @Test("an empty linked-account history is available and empty")
    @MainActor
    func emptyHistory() async {
        let cli = StubCLI()
        cli.payload = payload(
            available: 0,
            withdrawable: 0,
            earned: 0,
            jobs: 0,
            earnings: []
        )
        let store = ContributionsStore(cli: cli)
        await store.refresh()

        guard case .available = store.availability else {
            Issue.record("expected available, got \(store.availability)")
            return
        }
        #expect(store.isEmpty)
        #expect(store.snapshot?.records == [])
    }

    @Test("missing local machine identity never attributes another Mac's work")
    @MainActor
    func missingCurrentIdentity() async {
        let cli = StubCLI()
        cli.payload = payload(
            currentSerialNumber: nil,
            providers: providers
        )
        let store = ContributionsStore(cli: cli)
        await store.refresh()

        #expect(store.snapshot?.currentProviderKeys == [])
        #expect(store.filteredLedger.isEmpty)
        store.setScope(.allMacs)
        #expect(store.filteredLedger.count == 3)
    }

    @Test("transport failure surfaces the CLI's one-line guidance")
    @MainActor
    func fetchFailure() async {
        let cli = StubCLI()
        cli.error = ContributionsCLIError.exited(
            1,
            message: "Could not reach the coordinator at https://api.darkbloom.dev (offline). Check your connection and try again."
        )
        let store = ContributionsStore(cli: cli)
        await store.refresh()

        guard case .unavailable(let message) = store.availability else {
            Issue.record("expected unavailable, got \(store.availability)")
            return
        }
        #expect(message.contains("Could not reach the coordinator"))
        #expect(store.snapshot == nil)
    }

    @Test("an unlinked Mac surfaces login guidance")
    @MainActor
    func unlinkedGuidance() async {
        let cli = StubCLI()
        cli.error = ContributionsCLIError.exited(
            1,
            message: "This Mac is not linked to a provider account. Run `darkbloom login` to link it."
        )
        let store = ContributionsStore(cli: cli)
        await store.refresh()

        guard case .unavailable(let message) = store.availability else {
            Issue.record("expected unavailable, got \(store.availability)")
            return
        }
        #expect(message.contains("darkbloom login"))
    }

    @Test("the retry action refetches live stores and stays fixture-bound")
    @MainActor
    func retryRefetches() async {
        let cli = StubCLI()
        cli.error = ContributionsCLIError.exited(1, message: "offline")
        let store = ContributionsStore(cli: cli)
        await store.refresh()
        guard case .unavailable = store.availability else {
            Issue.record("expected unavailable")
            return
        }

        cli.error = nil
        cli.payload = payload()
        store.retryPreviewLoad()
        for _ in 0 ..< 100 where store.snapshot == nil {
            await Task.yield()
        }
        #expect(await cli.fetchCount == 2)
        guard case .available = store.availability else {
            Issue.record("expected available after retry, got \(store.availability)")
            return
        }

        let fixtureStore = ContributionsStore(fixture: .unavailable)
        fixtureStore.retryPreviewLoad()
        #expect(fixtureStore.snapshot != nil)
        #expect(await cli.fetchCount == 2)
    }
}

@Suite("ContributionsCLI payload parsing")
struct ContributionsCLIParsingTests {
    @Test("decodes linked earnings, provider mappings, and RFC3339Nano")
    func decode() throws {
        let json = """
        {
          "account_id": "acct-9",
          "current_provider_key": "key-9",
          "current_serial_number": "SERIAL-9",
          "available_balance_micro_usd": 1000000,
          "available_balance_usd": "1.000000",
          "withdrawable_balance_micro_usd": 750000,
          "withdrawable_balance_usd": "0.750000",
          "total_micro_usd": 1000000,
          "total_usd": "1.000000",
          "count": 1,
          "recent_count": 1,
          "history_limit": 1000,
          "providers": [
            {"provider_id":"session-9","provider_key":"key-9","serial_number":"SERIAL-9"}
          ],
          "earnings": [
            {
              "id": 7,
              "account_id": "acct-9",
              "provider_id": "session-9",
              "provider_key": "key-9",
              "amount_micro_usd": 1000000,
              "model": "gpt-oss-20b",
              "job_id": "job-9",
              "prompt_tokens": 123,
              "completion_tokens": 45,
              "created_at": "2026-08-17T22:04:31.123456789Z"
            }
          ]
        }
        """
        let payload = try JSONDecoder().decode(
            ContributionsEarningsPayload.self,
            from: Data(json.utf8)
        )
        #expect(payload.accountID == "acct-9")
        #expect(payload.currentProviderKey == "key-9")
        #expect(payload.availableBalanceMicroUSD == 1_000_000)
        #expect(payload.withdrawableBalanceMicroUSD == 750_000)
        #expect(payload.earnings[0].promptTokens == 123)
        #expect(payload.earnings[0].createdAt != nil)
        #expect(payload.providers[0].serialNumber == "SERIAL-9")
    }
}
