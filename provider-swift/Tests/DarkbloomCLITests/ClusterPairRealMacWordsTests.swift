import ArgumentParser
import Foundation
import Testing

@testable import ProviderCore
@testable import darkbloom

// What a paired Mac says of its pair where the real-Mac journeys found a false line (journey 3 on pair-2, and the
// reviews of #1908 and #1911). The pair is a fixture; nothing of this Mac's own cluster is read.

private let otherMac = "the other Mac (Apple M3 Ultra, 256 GB)"

private func pair(role: ClusterPairSummary.Role, started: Bool = true) -> ClusterPairSummary {
    var pair = ClusterPairSummary(paired: true)
    pair.role = role
    pair.thisMacName = "Jonathan's MacBook Pro"
    pair.otherMacName = "Apple M3 Ultra, 256 GB"
    pair.modelID = "EigenLabs/Qwen3.8-27B-4bit-mtp"
    pair.modelName = "Qwen 3.8 27B"
    pair.deployment = "Serving Qwen 3.8 27B across both Macs: tensor parallel, M3 Ultra 50% / M5 Max 50%"
    pair.started = started
    pair.serviceRunning = true
    return pair
}

/// A cluster service's status as a Mac publishes it, from its JSON.
private func status(_ json: String) throws -> ClusterServiceStatus {
    try JSONDecoder().decode(ClusterServiceStatus.self, from: Data(json.utf8))
}

@Suite("A paired Mac's words where pair-2 found them false (journey 3)", .serialized)
struct ClusterPairRealMacWordsTests {
    // MARK: - D1: the member's doctor said "loading" while the pair served

    /// The Mac that follows never writes the pair's line (only rank 0's part does, `ProviderLoop.serveCommittedStart`),
    /// so its own view can't tell a serving pair from a loading one. Its part registered as the pair's member read
    /// "loading" for as long as the pair served.
    @Test("the Mac that follows: its own view never says loading for a part registered as the pair's member")
    func aMembersOwnViewIsNotLoading() throws {
        let member = try status(#"{"serving":true,"sessionLeader":false,"child":{"running":true,"starts":1,"#
            + #""notice":"\#(ClusterLocalServing.offeredNotice)"}}"#)
        let (state, reason) = ClusterPairSummary.ownState(started: true, own: member)
        #expect(state != .loading, "the Mac that follows can't tell; got \(state)")
        #expect(reason == nil)
        // Rank 0's part registered as the pair's member, before its pair line, is still loading.
        let leader = try status(#"{"serving":true,"sessionLeader":true,"child":{"running":true,"starts":1,"#
            + #""notice":"\#(ClusterLocalServing.offeredNotice)"}}"#)
        #expect(ClusterPairSummary.ownState(started: true, own: leader) == (.loading, nil))
    }

    /// `doctor`'s pair line is `status`'s: on the Mac that follows, the leading Mac's answer (journey 3: the member's
    /// `status` said ✓ Serving while its `doctor` said "loading", twice, before and after `restart`).
    @Test("doctor's pair line reads the pair as status does: the leading Mac's answer on the Mac that follows")
    func doctorReadsThePairAsStatusDoes() async {
        var ownView = pair(role: .member)
        ownView.state = .unknown
        var leaderAnswer = pair(role: .member)
        leaderAnswer.read(status: ["Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel)."], leaderMode: nil)
        let (own, answered) = (ownView, leaderAnswer)
        let line = await ClusterPairSummary.$readerForTesting.withValue({ live in live ? answered : own }) {
            await Doctor.clusterLine(config: nil)
        }
        #expect(line == "Cluster: this Mac follows · \(otherMac) · Qwen 3.8 27B through Darkbloom · serving "
            + "(details: `darkbloom cluster status`)")
        let unpaired = await ClusterPairSummary.$readerForTesting.withValue({ _ in .notPaired }) { await Doctor.clusterLine(config: nil) }
        #expect(unpaired == nil)
    }

    // MARK: - D3: after `cluster leave` on the leading Mac, the Mac left behind

    /// Journey 3: once the Studio left, the MacBook's `status` said "this Mac (…) leads · the other Mac (…) follows"
    /// beside "isn't answering over the cable". This Mac's service took control, but nothing follows it.
    @Test("a Mac whose other Mac isn't answering names no roles: it can't tell that Mac left from it being away")
    func noRolesWhileTheOtherMacIsSilent() {
        var leftBehind = pair(role: .leader, started: false)
        leftBehind.read(status: ["degraded: serving on this Mac alone (the other Mac (Apple M3 Ultra, 256 GB) is gone; the cluster "
                                 + "re-forms by itself when it is back)."], leaderMode: "alone")
        #expect(leftBehind.clusterStatusLines.first
            == "Cluster: this Mac (Jonathan's MacBook Pro) is paired with \(otherMac), which isn't answering")
        #expect(leftBehind.clusterStatusLines.contains("■ Stopped; last model Qwen 3.8 27B."))
        var member = pair(role: .member)
        member.read(status: ["The other Mac (Apple M3 Ultra, 256 GB) did not answer over the cable: connection refused"], leaderMode: nil)
        #expect(member.clusterStatusLines.first
            == "Cluster: this Mac (Jonathan's MacBook Pro) is paired with \(otherMac), which isn't answering")
        // While it answers, the roles stand.
        var serving = pair(role: .member)
        serving.read(status: ["Serving Qwen 3.8 27B through Darkbloom on both Macs (tensor parallel)."], leaderMode: nil)
        #expect(serving.clusterStatusLines.first == "Cluster: this Mac (Jonathan's MacBook Pro) follows · \(otherMac) leads")
        // The one-line form (`status --solo`, and doctor when the leading Mac's answer doesn't come).
        var own = pair(role: .leader, started: false)
        own.state = .stopped
        own.otherMacAnswers = false
        #expect(own.statusLine == "Cluster: this Mac is paired · \(otherMac) isn't answering · Qwen 3.8 27B through Darkbloom · stopped "
            + "(details: `darkbloom cluster status`)")
    }

    // MARK: - #1911's review, N7: a Mac serving its pair's model alone

    /// The cluster service's solo server (the other Mac away, `child.solo`) serves this Mac alone, so a tool set up
    /// for it names its models `(this Mac)`, not `(your pair)`.
    @Test("the cluster service's solo server is not the pair's")
    func theSoloServerIsNotThePairs() {
        var solo = ClusterServiceStatus(role: "leader", serving: true, modelName: "m", sessionLeader: true, localRank: 0,
                                        setup: nil, child: .init(running: true, starts: 1, pid: 41, solo: true), session: nil)
        solo.servicePID = 40
        #expect(ClusterPairSummary.pairProcesses(of: solo).isEmpty)
        solo.child.solo = false
        #expect(ClusterPairSummary.pairProcesses(of: solo) == [41, 40])
    }

    // MARK: - #1908's review, nit 2: "Press Enter" when the other Mac is silent

    /// On a stopped pair whose other Mac doesn't answer, the leading Mac's screen first offers Try again / Start over /
    /// Quit, not the model list, so the line before it doesn't promise Enter starts the pair.
    @Test("a terminal start on a stopped pair says Enter starts it only while the other Mac answers")
    func pressEnterOnlyWhileTheOtherMacAnswers() {
        var stopped = pair(role: .leader, started: false)
        stopped.otherMacReachable = true
        #expect(stopped.screenLine == "This Mac is in a two-Mac cluster with \(otherMac), which is stopped. Press Enter to "
            + "start it with Qwen 3.8 27B (last used), or choose another model.")
        stopped.otherMacReachable = false
        #expect(stopped.screenLine == "This Mac is in a two-Mac cluster with \(otherMac): opening the pair's screen.")
    }
}

@Suite("Start: a mode flag beside --solo on a Mac in a pair (journey 3, D7)", .serialized)
struct StartSoloModeFlagTests {
    private static let config = """
        [provider]
        name = "ls5b-fixture"

        [local]
        mode = "both"
        port = 8001
        """

    /// Journey 3's delta: `start --solo --local …` on pair-2's Studio saved `[local] mode = 'local'`, while the pair
    /// went on serving Both. On a Mac in a pair `[local] mode` holds the pair's answer, so the flag serves this start
    /// alone that way and saves nothing.
    @Test("with --solo a mode flag serves that start only; without it, the flag is saved as before")
    func aSoloFlagIsForThatStartOnly() throws {
        let config = try TempConfig(Self.config)
        defer { config.remove() }
        let terminal = ScriptedTerminal()
        let solo = try terminal.resolve(config.start(["--solo", "--local", "--model", "m"]))
        #expect(solo.mode == .local)
        #expect(solo.change.mode == nil)
        #expect(config.local?.mode == .both, "the pair's answer stays")
        #expect(LocalFirstOptions(local: true, solo: true).savesModeFlag == false)
        let single = try terminal.resolve(config.start(["--local", "--model", "m"]))
        #expect(single.change.mode == .local)
        #expect(config.local?.mode == .local)
    }

    /// The pair's settings, as `darkbloom cluster` and an owner leave them: Both, its pause turned off, a route.
    private static let pairSettings = """
        [provider]
        name = "ls5b-fixture"

        [local]
        mode = "both"
        me_first = false
        route = "my-macs"
        port = 8001
        """

    /// #1931's review: `--solo --choose` saved its answer over the pair's `[local] mode`, D7's bug by another flag. No
    /// start asks now: beside `--solo`, a start with no mode saved serves the default (Both) for that start only, with
    /// the pair's own pause and route, and saves nothing.
    @Test("--solo without a saved mode serves Both for that start only, with the pair's settings, and saves nothing")
    func aSoloDefaultIsForThatStartOnly() throws {
        let config = try TempConfig(Self.pairSettings.replacingOccurrences(of: "mode = \"both\"\n", with: ""))
        defer { config.remove() }
        let before = config.bytes
        let solo = try ScriptedTerminal().resolve(config.start(["--solo", "--choose", "--model", "m"]), keySaved: true)
        #expect(solo.mode == .both && solo.source == .default && !solo.meFirst && solo.route == .myMacs)
        #expect(solo.change.isEmpty && solo.defaultLine != nil)
        #expect(config.bytes == before, "the pair's [local] stays as it was")
    }

    /// #1931's review: beside `--solo`, `--me-first` (over a saved `me_first = false`), `--no-me-first`, `--me-first-idle`
    /// and `--route` still wrote `[local]` keys the pair reads (its pause, its idle minutes, its router). The background
    /// service reads them from `[local]`, so beside `--solo` they can't serve that start alone: each is refused, naming
    /// the key, and nothing starts or is saved.
    @Test("beside --solo, a flag that would change a [local] key the pair reads is refused, and nothing is saved",
          arguments: [(["--me-first"], "me_first"), (["--no-me-first"], "me_first"),
                      (["--me-first-idle", "30"], "me_first_idle_minutes"), (["--route", "this-mac"], "route")])
    func aSoloSettingsFlagIsRefused(flags: [String], key: String) throws {
        // `--no-me-first` changes the pair's setting only where its pause is on (no `me_first` saved).
        let toml = flags == ["--no-me-first"] ? Self.pairSettings.replacingOccurrences(of: "me_first = false\n", with: "")
            : Self.pairSettings
        let config = try TempConfig(toml)
        defer { config.remove() }
        let before = config.bytes
        do {
            _ = try ScriptedTerminal().resolve(config.start(["--solo"] + flags + ["--model", "m"]))
            Issue.record("\(flags) was not refused")
        } catch let refusal as ValidationError {
            #expect(refusal.message.contains("[local] \(key)"), "\(refusal.message)")
            #expect(refusal.message.hasSuffix("Nothing was started or saved."), "\(refusal.message)")
        }
        #expect(config.bytes == before, "\(flags): nothing saved")
    }

    /// The same values as the pair's write nothing, so a solo start takes them.
    @Test("beside --solo, flags equal to the pair's settings serve, and nothing is saved")
    func aSoloStartWithThePairsOwnSettingsServes() throws {
        let config = try TempConfig(Self.pairSettings)
        defer { config.remove() }
        let before = config.bytes
        let solo = try ScriptedTerminal().resolve(
            config.start(["--solo", "--local-endpoint", "--no-me-first", "--route", "my-macs", "--model", "m"]))
        #expect(solo.mode == .both && !solo.meFirst && solo.route == .myMacs)
        #expect(solo.change.isEmpty)
        #expect(config.bytes == before)
    }
}

@Suite("darkbloom local names the key's file (journey 2a, J2-a)")
struct LocalKeyFileTests {
    private let home = URL(fileURLWithPath: "/Users/someone")

    @Test("one key file on one Mac; on the pair's API the pair's key file too")
    func theKeyFileIsNamed() {
        let own = home.appendingPathComponent(".darkbloom/local_token")
        let pairs = home.appendingPathComponent(".darkbloom/cluster_local_token")
        #expect(Local.keyFileLine(keyFile: own, pairKeyFile: nil, home: home) == "  key file: ~/.darkbloom/local_token")
        #expect(Local.keyFileLine(keyFile: own, pairKeyFile: pairs, home: home)
            == "  key file: ~/.darkbloom/local_token (the pair's key, in ~/.darkbloom/cluster_local_token, works here too)")
        #expect(Local.keyFileLine(keyFile: pairs, pairKeyFile: pairs, home: home) == "  key file: ~/.darkbloom/cluster_local_token")
        #expect(Local.keyFileLine(keyFile: nil, pairKeyFile: pairs, home: home) == nil)
    }
}

@Suite("A refusal from a command that ran, and ^C (journey 1, J-10 and J-7)")
struct RunRefusalWordsTests {
    /// Journey 1: every refusal a command made after it started ended with the root's generic "Usage: darkbloom
    /// <subcommand> / See 'darkbloom --help'…" block. The command's own words say what to do.
    @Test("a refusal after the parse is its own words, without the root's usage block")
    func aRefusalIsItsOwnWords() {
        let refusal = ValidationError("This Mac serves only the Darkbloom network, so OpenCode has no local address to use.")
        #expect(Darkbloom.refusalText(afterParse: refusal)
            == "Error: This Mac serves only the Darkbloom network, so OpenCode has no local address to use.")
        #expect(Darkbloom.refusalText(afterParse: CocoaError(.fileNoSuchFile)) == nil, "any other error keeps its usual output")
    }

    /// Journey 1: ^C on `start --local --here` printed `error darkbloom-provider: [HummingbirdCore] Server shutdown
    /// error: Already closed` and `Waiting on child channel: CancellationError()`: the server's own shutdown, nothing
    /// the owner has to act on.
    @Test("the local server's shutdown noise at ^C is dropped; its other lines are kept")
    func shutdownNoiseIsDropped() {
        #expect(QuietShutdownLogHandler.drops(source: "HummingbirdCore", message: "Server shutdown error: Already closed"))
        #expect(QuietShutdownLogHandler.drops(source: "HummingbirdCore", message: "Waiting on child channel: CancellationError()"))
        #expect(!QuietShutdownLogHandler.drops(source: "HummingbirdCore", message: "Server shutdown error: address in use"))
        #expect(!QuietShutdownLogHandler.drops(source: "darkbloom", message: "Server shutdown error: Already closed"))
    }
}
