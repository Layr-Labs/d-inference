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

    /// Two Macs of one kind share a hardware name: the lines name them "this Mac" and "the other Mac (<its name>)" for
    /// the screen that shows them, which for an answer to a forwarded command is the other Mac's (2026-10-25).
    @Test func linesNameTheTwoMacsForTheScreenThatShowsThem() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let live = fixture.live(peerPin: Fixture.peerPin)
        live.rememberPeerReport(Self.report(), memberID: fixture.pairing.peerMemberID)
        #expect(live.here == "this Mac" && live.hereShort == "this Mac")
        #expect(live.there == "the other Mac (Apple M5 Max, 96 GB)" && live.thereShort == "the other Mac")
        let forwarded = live.answeringForwarded { (live.here, live.hereShort, live.there, live.thereShort) }
        #expect(forwarded.0.hasPrefix("the other Mac (") && forwarded.1 == "the other Mac")
        #expect(forwarded.2 == "this Mac" && forwarded.3 == "this Mac")
        #expect(live.here == "this Mac", "the other Mac's wording ends with the answer")
        #expect(live.startsWhenItAnswers.hasPrefix("This Mac's cluster service starts the other Mac's part"))

        let ranks = Self.ranks(peerID: fixture.pairing.peerMemberID)
        let shown = live.planShares(ranks, localName: "Apple M3 Ultra, 256 GB", perspective: true)
        #expect(shown.map(\.label) == ["this Mac", "the other Mac"])
        #expect(ClusterOnboardingDeployment.sharesWords(mode: "pipeline_v1", shares: shown) == "this Mac 16 layers / the other Mac 16 layers")
        let answered = live.answeringForwarded { live.planShares(ranks, localName: "Apple M3 Ultra, 256 GB", perspective: true) }
        #expect(answered.map(\.label) == ["the other Mac", "this Mac"])
        // A line recorded for both Macs names each by its hardware.
        #expect(live.planShares(ranks, localName: "Apple M3 Ultra, 256 GB").allSatisfy { $0.label == nil })
    }

    /// Each Mac's teardown summary names it as the screen does; the other Mac's own answer names itself by hardware.
    @Test func teardownSummariesAreRenamedForTheScreen() {
        let other = "The other Mac (Apple M5 Ultra, 256 GB)"
        #expect(OnboardingLive.teardownLine("Apple M5 Ultra, 256 GB: nothing left running", mac: other) == other + ": nothing left running")
        #expect(OnboardingLive.teardownLine("Apple M5 Ultra, 256 GB: still running: a cluster process", mac: "This Mac")
            == "This Mac: still running: a cluster process")
        #expect(OnboardingLive.teardownLine("garbled", mac: "This Mac") == "garbled")
        // The update's release check still reads both renamed summaries.
        #expect(ClusterOnboardingUpdate.released(["This Mac: nothing left running", other + ": nothing left running"]))
    }

    /// One line per artifact and name (2026-10-25: GLM-5.3-Flash offered from the folder whose manifest the cluster
    /// worker pins, and "not supported on a cluster yet" right under it for the catalog's clone of the same bytes).
    @Test func theModelListShowsOneLinePerArtifactAndName() {
        typealias A = OnboardingLive.ListedArtifact
        let glm = A(aggregate: "3aae", files: "f1")
        let offered = ClusterOnboardingModelChoice(title: "Z.ai: GLM-5.3-Flash", lines: ["181.8 GB · tensor parallel"], blocker: nil,
                                                   modelID: "EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp")
        let clone = ClusterOnboardingModelChoice(title: "Z.ai: GLM-5.3-Flash", lines: [], blocker: ClusterSetupPlanning.notClusterModel,
                                                 modelID: "glm-5.3-flash")
        func kept(_ choices: [ClusterOnboardingModelChoice], _ artifacts: [A?], servable: Set<String> = ["3aae"]) -> [(Int, String?)] {
            OnboardingLive.presentedChoices(choices, artifacts: artifacts, servable: servable).map { ($0.index, $0.choice.blocker) }
        }
        #expect(kept([offered, clone], [glm, glm]).map(\.0) == [0])
        // Only the copy the worker does not take: the model is still one a pair serves.
        #expect(kept([clone], [glm]).map(\.1) == [ClusterSetupPlanning.copyNotTaken])
        #expect(kept([clone], [glm], servable: []).map(\.1) == [ClusterSetupPlanning.notClusterModel], "an artifact this build does not serve")
        // Two catalog entries that share every file keep their own lines.
        var renamed = clone
        renamed.title = "Z.ai: GLM-5.3-Flash (8-bit)"
        #expect(kept([offered, renamed], [glm, glm]).map(\.0) == [0, 1])
        // Another files digest is another artifact; an older build's missing digest matches any.
        #expect(kept([offered, clone], [glm, A(aggregate: "3aae", files: "f2")]).map(\.0) == [0, 1])
        #expect(kept([offered, clone], [A(aggregate: "3aae", files: nil), glm]).map(\.0) == [0])
        // Neither can be served: the reason that is not the copy itself is said once.
        var tooLarge = offered
        tooLarge.blocker = "Too large for these Macs together right now."
        #expect(kept([clone, tooLarge], [glm, glm]).map(\.0) == [1])
        let twice = kept([clone, clone], [glm, glm])
        #expect(twice.map(\.0) == [0] && twice.first?.1 == ClusterSetupPlanning.copyNotTaken)
        // A choice the list cannot compare (no artifact) is kept as it is.
        #expect(kept([offered, clone], [nil, glm]).map(\.0) == [0, 1])
        #expect(kept([offered], [glm]).first?.1 == nil)
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
