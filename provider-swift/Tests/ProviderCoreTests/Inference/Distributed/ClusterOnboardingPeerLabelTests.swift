import Foundation
import Testing
@testable import ProviderCore

struct ClusterOnboardingPeerLabelTests {
    @Test func freshPeerFactsReplaceSavedMachineAndPlanLabelsWithoutChangingIntent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let live = fixture.live(peerPin: Fixture.peerPin)
        let before = try fixture.store.readRecord().leadership
        // Supply the report at the authenticated exchange boundary; no transport,
        // hardware probe, installed service, or live pairing store is exercised.
        live.rememberPeerReport(Self.report(), memberID: fixture.pairing.peerMemberID)
        #expect(live.peerName == "Apple M5 Max, 96 GB")
        #expect(live.resume().peerName == "Apple M5 Max, 96 GB")
        let shares = live.planShares(Self.ranks(peerID: fixture.pairing.peerMemberID), localName: "Apple M3 Ultra, 256 GB")
        #expect(shares.map(\.name) == ["Apple M3 Ultra, 256 GB", "Apple M5 Max, 96 GB"])
        #expect(shares.map(\.layers) == [16, 16])
        let line = ClusterOnboardingDeployment.line(model: "fixture-model", mode: "pipeline", shares: shares)
        #expect(line.contains("M5 Max"))
        #expect(!line.contains("M4 Max"))
        #expect(live.resume().modelName == "saved-model")
        #expect(try fixture.store.readRecord().leadership == before)
    }

    @Test func missingFreshReportKeepsSavedName() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let live = fixture.live(peerPin: Fixture.peerPin)
        #expect(live.peerName == "Apple M4 Max, 128 GB")
        #expect(live.resume().role == .leader)
        #expect(live.resume().modelName == "saved-model")
    }

    @Test func changedPeerPinCannotResumeOrReuseOldPeerDisplayFacts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let live = fixture.live(peerPin: String(repeating: "c", count: 64))
        live.rememberPeerReport(Self.report(), memberID: fixture.pairing.peerMemberID)
        #expect(live.resume().role == nil)
        #expect(live.resume().modelName == nil)
        #expect(live.peerName == "Apple M4 Max, 128 GB")
        #expect(try fixture.store.readRecord().leadership?.peerPin == Fixture.peerPin)
    }

    @Test func peerDisplaySanitizesControlCharactersAndUsesRemoteMemory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let live = fixture.live(peerPin: Fixture.peerPin)
        var report = Self.report()
        report.mac.chip = "Apple M5\nMax\u{1B}"
        live.rememberPeerReport(report, memberID: fixture.pairing.peerMemberID)
        #expect(live.peerName == "Apple M5Max, 96 GB")
    }

    private static func report() -> ClusterSetupReport {
        .init(observedAt: "2026-10-17T00:00:00Z", version: "fixture",
              mac: .init(profile: nil, profileError: nil, chip: "Apple M5 Max", physicalMemoryBytes: 96 << 30,
                         osVersion: "26.2", osMajor: 26, osMinor: 2, diskFreeBytes: nil, diskTotalBytes: nil),
              link: .init(state: "ready", guidance: nil, port: nil, portsDown: 0, thunderbolt: nil, thunderboltError: nil),
              saved: .notConfigured, inbox: nil, journal: .absent,
              memoryGuard: .init(decision: .clear, wiredBytes: nil, baselineBytes: nil, detail: nil),
              models: [], modelsError: nil, pairingCode: nil, checks: [])
    }

    private static func ranks(peerID: String) -> [ClusterSetupPlanSummary.Rank] {
        [1, 0].map { rank in
            .init(rank: rank, memberID: rank == 0 ? "local" : peerID, local: rank == 0,
                  firstLayer: rank * 16, endLayer: (rank + 1) * 16, weightsBytes: 1024, needBytes: 2048,
                  admissibleNowBytes: 4096, physicalMemoryBytes: 8192, fit: "now", fitDetail: "fits", shortBytes: nil)
        }
    }

    private struct Fixture {
        static let peerPin = String(repeating: "b", count: 64)
        let home: URL
        let store: ClusterSetupStore
        let context: LiveContext
        let settings: ClusterOnboardingOperations.LiveSettings
        let pairing: ClusterSetupLinkExchange.Pairing

        init() throws {
            home = try NativePairMemberFixture.privateRoot()
            let paths = try ClusterUserPaths(homeDirectory: home)
            store = ClusterSetupStore(paths: .init(paths: paths))
            let wizard = ClusterSetupOperations.LiveSettings(providerConfiguration: home.appendingPathComponent("provider.toml"),
                darkbloomExecutable: home.appendingPathComponent("not-executed"), sessionArguments: [], pair: nil, dryRun: true, version: "fixture")
            context = LiveContext(paths: paths, store: store, settings: wizard,
                                  clean: ClusterConsoleFreeText(homeDirectory: home.path))
            settings = .init(service: .init(wizard: wizard, leaderArguments: [], followerArguments: []), serviceArguments: [])
            pairing = Self.pairing(peerPin: Self.peerPin)
            var leadership = ClusterOnboardingLeadership(role: "leader", leaderPin: pairing.localPin,
                peerPin: Self.peerPin, peerName: "Apple M4 Max, 128 GB", since: "2026-10-17T00:00:00Z")
            leadership.modelName = "saved-model"
            _ = try store.updateRecord { $0.leadership = leadership }
        }

        func live(peerPin: String) -> OnboardingLive {
            let pairing = Self.pairing(peerPin: peerPin)
            return OnboardingLive(context: context, store: store, settings: settings, readPairing: { pairing })
        }

        func remove() { try? FileManager.default.removeItem(at: home) }

        private static func pairing(peerPin: String) -> ClusterSetupLinkExchange.Pairing {
            .init(localPin: String(repeating: "a", count: 64), peerPin: peerPin, clusterID: "fixture",
                  linkEpoch: "fixture", edgeID: "fixture", secretFile: "/not-read", secret: Data(repeating: 0, count: 32))
        }
    }
}
