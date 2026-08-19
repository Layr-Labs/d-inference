import Foundation
import Testing
@testable import DarkbloomApp

// Live ContributionsStore: feeds from `darkbloom earnings --json`, maps the
// coordinator's wallet-keyed payload into MicroUSD-exact snapshot state, and
// surfaces loading / unavailable distinctly from fixture states.
@Suite("ContributionsStore live mode")
struct ContributionsLiveTests {

    actor StubCLI: ContributionsCLIRunning {
        nonisolated(unsafe) var payload: ContributionsEarningsPayload?
        nonisolated(unsafe) var error: (any Error)?
        private(set) var fetchCount = 0

        func fetchEarnings() async throws -> ContributionsEarningsPayload {
            fetchCount += 1
            if let error { throw error }
            guard let payload else {
                throw ContributionsCLIError.invalidOutput("stub has no payload")
            }
            return payload
        }
    }

    private func payload(
        wallet: String? = "acct-live-1",
        balance: Int64 = 1_350_000,
        earned: Int64 = 2_250_000,
        jobs: Int = 2,
        payouts: [ContributionsEarningsPayload.Payout] = []
    ) -> ContributionsEarningsPayload {
        ContributionsEarningsPayload(
            wallet: wallet,
            balanceMicroUSD: balance,
            totalEarnedMicroUSD: earned,
            totalJobs: jobs,
            payouts: payouts,
            ledger: [])
    }

    private var samplePayouts: [ContributionsEarningsPayload.Payout] {
        [
            ContributionsEarningsPayload.Payout(
                id: 42, providerAddress: "acct-live-1", amountMicroUSD: 900_000,
                model: "qwen3.5-9b", jobID: "job-2",
                timestamp: Date(timeIntervalSince1970: 1_800_000_000), settled: false),
            ContributionsEarningsPayload.Payout(
                id: 0, providerAddress: "acct-live-1", amountMicroUSD: 450_000,
                model: nil, jobID: "job-1",
                timestamp: Date(timeIntervalSince1970: 1_799_000_000), settled: true),
        ]
    }

    @Test("live init starts loading; refresh maps the payload")
    @MainActor
    func refreshMapsPayload() async throws {
        let cli = StubCLI()
        cli.payload = payload(payouts: samplePayouts)
        let store = ContributionsStore(cli: cli, now: { Date(timeIntervalSince1970: 1_800_001_000) })

        #expect(store.availability == .loading)
        #expect(store.snapshot == nil)

        await store.refresh()

        guard case .available = store.availability else {
            Issue.record("expected available, got \(store.availability)")
            return
        }
        let snapshot = try #require(store.snapshot)
        #expect(snapshot.currentProviderKey == "acct-live-1")
        #expect(snapshot.availableBalance == MicroUSD(1_350_000))
        #expect(snapshot.withdrawableBalance == snapshot.availableBalance)
        #expect(snapshot.earnedLifetime == MicroUSD(2_250_000))
        #expect(snapshot.lifetimeJobs == 2)
        #expect(snapshot.minimumPayout == ContributionsLiveMapping.liveMinimumPayout)
        #expect(snapshot.payoutReadiness == .ready)
        // The preview pulse series must never present observed account data.
        #expect(store.pulsePreview == nil)
    }

    @Test("payout rows map to records with stable ids and the unknown-model fallback")
    @MainActor
    func recordsMapping() async throws {
        let cli = StubCLI()
        cli.payload = payload(payouts: samplePayouts)
        let store = ContributionsStore(cli: cli, now: { Date(timeIntervalSince1970: 1_800_001_000) })
        await store.refresh()

        let records = try #require(store.snapshot?.records)
        #expect(records.count == 2)

        let settled = records.first { $0.id == "payout-42" }
        #expect(settled?.modelID == "qwen3.5-9b")
        #expect(settled?.providerKey == "acct-live-1")
        #expect(settled?.providerID == "job-2")
        #expect(settled?.providerName == "This Mac")
        #expect(settled?.amount == MicroUSD(900_000))
        #expect(settled?.totalTokens == 0, "wallet payouts carry no token counts")

        // Ledger-reconstructed rows (id 0) key off the job id, and a missing
        // model must not violate the snapshot's non-empty-model invariant.
        let reconstructed = records.first { $0.id == "job-job-1" }
        #expect(reconstructed?.modelID == "unknown")
        #expect(reconstructed?.modelName == "unknown")
        #expect((records.map(\.id).count) == Set(records.map(\.id)).count)
    }

    @Test("scope filters this-Mac records against the snapshot's provider key")
    @MainActor
    func scopeFiltering() async {
        let cli = StubCLI()
        cli.payload = payload(payouts: samplePayouts)
        let store = ContributionsStore(cli: cli, now: { Date(timeIntervalSince1970: 1_800_001_000) })
        await store.refresh()

        #expect(store.filteredLedger.count == 2, "both payouts key to the queried wallet")
        store.setScope(.allMacs)
        #expect(store.filteredLedger.count == 2)
        #expect(store.scope == .allMacs)
    }

    @Test("an empty wallet history is available-and-empty, not an error")
    @MainActor
    func emptyHistory() async {
        let cli = StubCLI()
        cli.payload = payload(balance: 0, earned: 0, jobs: 0, payouts: [])
        let store = ContributionsStore(cli: cli, now: { Date(timeIntervalSince1970: 1_800_001_000) })
        await store.refresh()

        guard case .available = store.availability else {
            Issue.record("expected available, got \(store.availability)")
            return
        }
        #expect(store.isEmpty)
        #expect(store.snapshot?.records == [])
    }

    @Test("a bare coordinator payload without the wallet echo still maps")
    @MainActor
    func missingWalletEcho() async {
        let cli = StubCLI()
        cli.payload = payload(wallet: nil, payouts: samplePayouts)
        let store = ContributionsStore(cli: cli, now: { Date(timeIntervalSince1970: 1_800_001_000) })
        await store.refresh()

        #expect(store.snapshot?.currentProviderKey == "unknown-wallet")
        // Records still satisfy the snapshot invariants (non-empty key).
        #expect(store.snapshot?.records.allSatisfy { !$0.providerKey.isEmpty } == true)
    }

    @Test("transport failure surfaces unavailable with the CLI's one-line guidance")
    @MainActor
    func fetchFailure() async {
        let cli = StubCLI()
        cli.error = ContributionsCLIError.exited(
            1, message: "Could not reach the coordinator at https://api.darkbloom.dev (offline). Check your connection and try again.")
        let store = ContributionsStore(cli: cli, now: { Date(timeIntervalSince1970: 1_800_001_000) })
        await store.refresh()

        guard case .unavailable(let message) = store.availability else {
            Issue.record("expected unavailable, got \(store.availability)")
            return
        }
        #expect(message.contains("Could not reach the coordinator"))
        #expect(store.snapshot == nil)
    }

    @Test("unlinked Mac surfaces the CLI's login guidance")
    @MainActor
    func unlinkedGuidance() async {
        let cli = StubCLI()
        cli.error = ContributionsCLIError.exited(
            1, message: "No linked account found for this Mac. Run `darkbloom login` to link it, or pass --wallet <address>.")
        let store = ContributionsStore(cli: cli, now: { Date(timeIntervalSince1970: 1_800_001_000) })
        await store.refresh()

        guard case .unavailable(let message) = store.availability else {
            Issue.record("expected unavailable, got \(store.availability)")
            return
        }
        #expect(message.contains("darkbloom login"))
    }

    @Test("the retry action refetches for live stores (and stays fixture-bound for previews)")
    @MainActor
    func retryRefetches() async {
        let cli = StubCLI()
        cli.error = ContributionsCLIError.exited(1, message: "offline")
        let store = ContributionsStore(cli: cli, now: { Date(timeIntervalSince1970: 1_800_001_000) })
        await store.refresh()
        #expect(store.availability != .loading)
        guard case .unavailable = store.availability else {
            Issue.record("expected unavailable")
            return
        }

        cli.error = nil
        cli.payload = payload()
        store.retryPreviewLoad()

        // retryPreviewLoad only fires its live refetch from `.unavailable`.
        for _ in 0 ..< 100 where store.snapshot == nil {
            await Task.yield()
        }
        #expect(await cli.fetchCount == 2)
        guard case .available = store.availability else {
            Issue.record("expected available after retry, got \(store.availability)")
            return
        }
        #expect(store.snapshot?.currentProviderKey == "acct-live-1")

        // Fixture stores remain deterministic: retry swaps back to the
        // active fixture, no fetch ever happens.
        let fixtureStore = ContributionsStore(fixture: .unavailable)
        #expect(fixtureStore.snapshot == nil)
        fixtureStore.retryPreviewLoad()
        #expect(fixtureStore.snapshot != nil)
        #expect(await cli.fetchCount == 2, "fixtures must never hit the CLI")
    }
}

// MARK: - Payload decoding

@Suite("ContributionsCLI payload parsing")
struct ContributionsCLIParsingTests {
    @Test("decodes the coordinator shape, null ledger, and RFC3339Nano")
    func decode() throws {
        let json = """
        {
          "wallet": "acct-9",
          "balance_micro_usd": 1000000,
          "balance_usd": "1.000000",
          "total_earned_micro_usd": 1000000,
          "total_earned_usd": "1.000000",
          "total_jobs": 1,
          "payouts": [
            {
              "id": 7,
              "provider_address": "acct-9",
              "amount_micro_usd": 1000000,
              "model": "gpt-oss-20b",
              "job_id": "job-9",
              "timestamp": "2026-08-17T22:04:31.123456789Z",
              "settled": true
            }
          ],
          "ledger": null
        }
        """
        let payload = try JSONDecoder().decode(ContributionsEarningsPayload.self, from: Data(json.utf8))
        #expect(payload.wallet == "acct-9")
        #expect(payload.balanceMicroUSD == 1_000_000)
        #expect(payload.payouts.count == 1)
        #expect(payload.payouts[0].timestamp != nil)
        #expect(payload.ledger == [])
    }
}
