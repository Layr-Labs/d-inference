import Foundation
import Testing
import DarkbloomClusterRemote

@testable import ProviderCore

/// The words for a stopped pair were chosen by looking for a few letters anywhere in the cause's text, so a cause
/// whose code happened to contain them was said as something else. Each case here is one such cause, read through the
/// entry point that takes the text of a status (`ClusterOnboardingNotServing.words(reason:mac:viewerRank:)`).
@Suite("A stopped pair's cause is said as what it is")
struct ClusterPairStopWordsTests {
    typealias Words = ClusterOnboardingNotServing
    static let mac = "one of the Macs"

    /// `device_busy` is an unresolved device journal (an earlier session's owner or worker was not seen to exit). It
    /// contains "busy", so it read "One of the Macs is busy with other work", which is what the coordinator's refusal
    /// of a provider that is not idle means.
    @Test func anUnresolvedDeviceJournalIsNotAMacBusyWithOtherWork() {
        let said = Words.words(reason: "device_busy", mac: Self.mac, viewerRank: 0)
        #expect(said == "An earlier session still holds the cluster device of one of the Macs")
        #expect(said != Words.words(reason: "idle:false", mac: Self.mac), "the coordinator's refusal keeps its own words")
        #expect(Words.remedy(forReason: said) == "Run `\(ClusterOnboardingCommand.name) cluster recover` on each Mac, then Retry.")
    }

    /// `version_mismatch` (the two ranks' workers speak different protocol versions) had no words and read "The pair
    /// stopped (version_mismatch)". It never clears by itself, as two Macs on different releases never do
    /// (`ClusterOnboardingVersionSplit`).
    @Test func aVersionMismatchSaysTheTwoMacsRunDifferentVersions() {
        let said = Words.words(reason: "version_mismatch", mac: Self.mac, viewerRank: 0)
        #expect(said == "The two Macs run different Darkbloom versions")
        #expect(Words.remedy(forReason: said) == "Run `\(ClusterOnboardingCommand.name) update` on both Macs, then Retry.")
    }

    /// `worker_runtime_unverified` (the installed worker's bytes differ from the saved setup) contains the
    /// coordinator's trust word `runtime_unverified`, so it read "isn't verified by Apple yet … retries by itself", and
    /// with both Macs verified "The coordinator didn't accept the pair yet". Neither Apple nor the coordinator is its
    /// cause, and no retry mends it.
    @Test func aWorkerThatIsNotTheSetupsIsNeitherApplesNorTheCoordinators() {
        for anyUnverified in [true, false] {
            let said = Words.words(reason: "worker_runtime_unverified", mac: Self.mac, anyUnverified: anyUnverified, viewerRank: 0)
            #expect(said == "The pair stopped (worker_runtime_unverified)", "any Mac unverified: \(anyUnverified)")
            #expect(Words.remedy(forReason: said) == nil)
        }
    }
}

/// What the build before the typed cause (`dev` at 0f78662e6b) did with a stopped line's text and with a status
/// line's reason, kept here word for word. The other Mac of a pair may still run it, so it is what reads this build's
/// text there. `ClusterPairStopCauseTests.theEarlierBuildsReaderIsKeptFaithfully` holds it to what that build printed.
private enum EarlierBuildReader {
    static func sentence(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }

    static func words(reason: String, mac: String, viewerRank: Int? = nil) -> String {
        if let short = memoryShort(reason) {
            let who = viewerRank.map { $0 == short.rank ? "this Mac" : "the other Mac" } ?? mac
            return "\(sentence(who)) doesn't have enough free memory for its share (needs \(short.needs) GiB, has \(short.has) GiB)"
        }
        let reason = reason.lowercased()
        let trust = ["trust_floor", "private_text", "app_attest", "no_trust_evidence", "runtime_unverified", "challenge_stale",
                     "attestation", "untrusted", "private_only"]
        if trust.contains(where: reason.contains) {
            return "\(sentence(mac)) isn't verified by Apple yet; Darkbloom retries by itself within minutes. Don't restart either Mac until then"
        }
        if reason.contains("memory_gate") || reason.contains("free_memory") || reason.contains("no_headroom") {
            return "\(sentence(mac)) lacks free memory for its share"
        }
        if reason.contains("serves_model") || reason.contains("not_serving_model") {
            return "The coordinator doesn't let \(mac) serve this model in a pair"
        }
        if reason.contains("offline") || reason.contains("heartbeat") || reason.contains("not_logged_in") {
            return "\(sentence(mac)) isn't connected to Darkbloom"
        }
        if reason.contains("idle:") || reason.contains("busy") { return "\(sentence(mac)) is busy with other work" }
        if reason.contains("release") || reason.contains("build_hash") { return "The two Macs run different Darkbloom builds" }
        if reason.contains("clock") { return "The clock of \(mac) is off; turn on Set time automatically there" }
        let plain = !reason.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }
        return "The pair stopped (\(reason.count <= 80 && plain ? reason : "no reason given"))"
    }

    static func memoryShort(_ reason: String) -> (rank: Int, needs: String, has: String)? {
        let prefix = "memory_gate_refused: rank "
        guard reason.hasPrefix(prefix) else { return nil }
        let parts = reason.dropFirst(prefix.count).split(separator: " ")
        guard parts.count == 7, let rank = Int(parts[0]), parts[1] == "needs", let needs = Double(parts[2]),
              parts[4] == "has", let has = Double(parts[5]) else { return nil }
        return (rank, String(format: "%.1f", needs), String(format: "%.1f", has))
    }

    /// Whether that build read anything into a status line's reason: a remedy under it, an end to a start's wait, a
    /// reason kept over the 15-minute line, progress. A reason none of these match is shown there as it is.
    static func readsInto(_ reason: String) -> Bool {
        reason.contains("logged in to Darkbloom") || reason.contains("isn't verified by Apple yet")
            || reason.contains("lacks free memory") || reason.contains("enough free memory for its share")
            || reason.hasPrefix("Not serving publicly: ") || reason.contains("the two Macs run different Darkbloom versions")
            || reason.contains("The clock of") || reason.contains("doesn't let") || reason.contains("run different Darkbloom builds")
            || reason.hasPrefix("not offered to Darkbloom") || reason.hasPrefix("The pair can't start: a single-Mac Darkbloom provider")
            || reason.hasPrefix("The coordinator does not pair Macs for ")
            || reason == "waiting for the coordinator to pair both Macs" || reason == "the coordinator paired both Macs"
            || (reason.hasPrefix("checking ") && reason.hasSuffix(" with Apple")) || reason.contains("'s part ended (")
    }
}

/// One table over every cause a pair's stop can have. Before the cause was a value, each hop from the part that
/// stopped to the screen read the previous hop's text again (the incident's rule, the part's line, the status, the
/// words, the remedy), and a fix at one hop left the others as they were.
@Suite("Every cause of a pair's stop is written once, read back the same and said as what it is")
struct ClusterPairStopCauseTests {
    typealias Cause = ClusterPairStopCause
    typealias Report = ClusterOnboardingPairReport
    typealias Words = ClusterOnboardingNotServing

    static let followerSaid = "its owner ended cleanly: darkbloom-cluster-worker: Tensor-parallel shard load needs 73.57 GiB of "
        + "admissible memory and has 68.20 GiB: 22.5 GiB free plus 45.7 GiB of file cache"
    static let refusal = Cause.MemoryRefusal(rank: 1, said: followerSaid)!

    /// Every cause a part can write: each guidance code, each fixed cause, each way a session ends, a rank's refusal.
    static let everyCause: [Cause] = Cause.Guidance.allCases.map(Cause.guidance) + Cause.fixed + [.memoryRefused(refusal)]
    static let macs = ["one of the Macs", "this Mac", "the other Mac (Apple M5 Max, 128 GB)"]
    static let viewerRanks: [Int?] = [nil, 0, 1]

    /// The codes are the incident log's own: every reason's guidance and each SSH guidance has a case here, and no
    /// case here is unknown there. A reason added there fails this until it is listed, and then it needs its words.
    @Test func theGuidanceCodesAreTheIncidentLogs() {
        for reason in ClusterFailureReason.allCases {
            let code = ClusterGuidance.guidance(for: reason).code
            #expect(Cause.Guidance(rawValue: code) != nil, "\(reason.rawValue) is recorded with \(code), which has no case")
        }
        let sshFailures = ["No ED25519 host key is known for 10.0.0.2", "REMOTE HOST IDENTIFICATION HAS CHANGED",
                           "no matching host key type found", "Permission denied (publickey)"]
        let sshCodes = sshFailures.map { ClusterFailureClassifier.classify(message: $0).guidance.code }
        #expect(sshCodes == ["host_key_unknown", "host_identity_changed", "no_matching_host_key", "login_rejected"])
        for code in sshCodes { #expect(Cause.Guidance(rawValue: code) != nil, "\(code)") }
        for code in Cause.Guidance.allCases {
            #expect(ClusterGuidance.guidance(code: code.rawValue)?.code == code.rawValue, "\(code.rawValue) is no guidance code")
        }
        let recorded = Set(ClusterFailureReason.allCases.map { ClusterGuidance.guidance(for: $0).code } + sshCodes)
        #expect(Set(Cause.Guidance.allCases.map(\.rawValue)) == recorded)
    }

    /// The text a cause writes is its own, and reads back as that cause: from the line, and from the status's text.
    /// Text no cause writes reads as `other` and is written back unchanged.
    @Test func everyCauseIsWrittenOnceAndReadsBackTheSame() {
        let texts = Self.everyCause.map(\.logText)
        #expect(Set(texts).count == texts.count, "two causes write the same text")
        for cause in Self.everyCause {
            #expect(Cause(logText: cause.logText) == cause, "\(cause.logText)")
            #expect(Report.latest(inLog: "Pair: starting\n" + Report.stoppedLine(cause) + "\n") == .stopped(cause), "\(cause.logText)")
            #expect(Report.state(Report.text(.stopped(cause))) == .stopped(cause), "\(cause.logText)")
        }
        for text in ["", "liveness:trust_floor", "Device_Busy", "committed start ended: a later build's reason",
                     "memory_gate_refused: rank 1  needs 73.57 GiB, has 68.20 GiB", "memory_gate_refused: rank 01 needs 1 GiB, has 2 GiB"] {
            #expect(Cause(logText: text) == .other(text) && Cause(logText: text).logText == text, "\(text)")
        }
    }

    /// The leading Mac's part makes the cause of a failed start from the incident it recorded: no incident, the
    /// incident's code, or the refusal of the Mac that follows with both of its figures.
    @Test func aFailedStartsCauseIsItsIncidents() {
        let error = "notServing(\"the pair did not become ready: closed; rank 1 said: \(Self.followerSaid)\")"
        #expect(Cause.failedStart(guidance: nil, error: error) == .didNotForm)
        #expect(Cause.failedStart(guidance: "memory_gate_refused", error: error) == .memoryRefused(Self.refusal))
        #expect(Self.refusal.rank == 1 && Self.refusal.needs == "73.57" && Self.refusal.has == "68.20")
        #expect(Cause.failedStart(guidance: "memory_gate_refused", error: "notServing(\"closed\")") == .guidance(.memoryGateRefused))
        #expect(Cause.failedStart(guidance: "peer_lost", error: error) == .guidance(.peerLost))
        // A code this build does not list is written as it is.
        #expect(Cause.failedStart(guidance: "a_later_code", error: error) == .other("a_later_code"))
        #expect(Cause.failedStart(guidance: "a_later_code", error: error).logText == "a_later_code")
    }

    /// The copy of the earlier build's reader says what that build printed, for every text recorded from it
    /// (`ClusterPairStopGoldenTests`) and for the three codes whose words it got wrong.
    @Test func theEarlierBuildsReaderIsKeptFaithfully() {
        for row in ClusterPairStopGoldenTests.words {
            #expect(EarlierBuildReader.words(reason: row.text, mac: Self.macs[0]) == row.words, "\(row.text)")
        }
        for row in ClusterPairStopGoldenTests.memoryWords {
            #expect(EarlierBuildReader.words(reason: row.text, mac: Self.macs[0]) == row.unknown, "\(row.text)")
            #expect(EarlierBuildReader.words(reason: row.text, mac: Self.macs[0], viewerRank: 0) == row.rankZero, "\(row.text)")
            #expect(EarlierBuildReader.words(reason: row.text, mac: Self.macs[0], viewerRank: 1) == row.rankOne, "\(row.text)")
        }
        #expect(EarlierBuildReader.words(reason: "device_busy", mac: Self.macs[0]) == "One of the Macs is busy with other work")
        #expect(EarlierBuildReader.words(reason: "version_mismatch", mac: Self.macs[0]) == "The pair stopped (version_mismatch)")
        #expect(EarlierBuildReader.words(reason: "worker_runtime_unverified", mac: Self.macs[0]) == ClusterPairStopGoldenTests.notVerified)
    }

    /// What this build writes that the earlier build did not: how the session ended, after the words that build wrote.
    /// The other Mac on that build shows each byte for byte: short enough, plain, lower case (it shows every reason in
    /// lower case) and none of the words it looks for. Both screens show the text, so it names no Mac. This build's
    /// new sentences are likewise nothing that build reads anything into.
    @Test func whatIsNewIsShownAsItIsByTheEarlierBuild() {
        for end in Cause.SessionEnd.allCases {
            let text = Cause.sessionEnded(end).logText
            #expect(text.hasPrefix("committed start ended: "), "\(text)")
            #expect(text.count <= Cause.earlierBuildShownCharacters, "\(text.count) characters: \(text)")
            #expect(!text.contains("this Mac") && !text.contains("other Mac"), "\(text)")
            for viewerRank in Self.viewerRanks {
                #expect(EarlierBuildReader.words(reason: text, mac: Self.macs[0], viewerRank: viewerRank) == "The pair stopped (\(text))",
                        "\(text)")
            }
        }
        // Every other cause writes what that build wrote: a guidance code, one of its five fixed texts, a rank's refusal.
        typealias Golden = ClusterPairStopGoldenTests
        let earlier = Set(Golden.codesSaidAsTheyAre + Golden.codesWithCorrectedWords + Golden.fixedWords
            + ["memory_gate_refused", "model_busy", Golden.memoryWords[0].text])
        for cause in Self.everyCause where !earlier.contains(cause.logText) {
            if case .sessionEnded(_?) = cause { continue }
            Issue.record("\(cause.logText) is text the earlier build never wrote, and nothing here says how it reads it")
        }
        // A sentence the earlier build would not have said for the same text, or says for new text, is one it reads
        // nothing into when the leading Mac answers it with it.
        var newSentences = Set<String>()
        for mac in Self.macs {
            for cause in Self.everyCause {
                for viewerRank in Self.viewerRanks {
                    let said = Words.words(cause, mac: mac, viewerRank: viewerRank)
                    let before = EarlierBuildReader.words(reason: cause.logText, mac: mac, viewerRank: viewerRank)
                    guard said != before || !earlier.contains(cause.logText) else { continue }
                    newSentences.insert(said)
                    #expect(!EarlierBuildReader.readsInto(said), "\(said)")
                }
            }
        }
        // The device journal on each of three Macs, the version mismatch, the worker, and nine session ends.
        #expect(newSentences.count == 3 + 1 + 1 + Cause.SessionEnd.allCases.count, "\(newSentences.sorted())")
    }

    /// The words of each cause are its own. A cause without a sentence is said with its text, never as "no reason
    /// given". No cause is said in the words of what the coordinator refuses a pair for (Apple verification, a Mac not
    /// connected, a model it does not let a Mac serve, different builds, the clock), nor as the coordinator's own, with
    /// or without both Macs verified by Apple: the coordinator committed the start. Two causes never read the same.
    @Test func everyCauseIsSaidAsWhatItIs() {
        let ownSentences: [Cause] = [.memoryRefused(Self.refusal), .guidance(.memoryGateRefused), .guidance(.deviceBusy),
                                     .guidance(.versionMismatch), .guidance(.modelBusy)]
        for mac in Self.macs {
            var said: [String: Cause] = [:]
            for cause in Self.everyCause {
                for viewerRank in Self.viewerRanks {
                    let words = Words.words(cause, mac: mac, viewerRank: viewerRank)
                    #expect(words == Words.words(reason: cause.logText, mac: mac, viewerRank: viewerRank), "\(cause.logText)")
                    for anyUnverified in [true, false] {
                        #expect(Words.words(cause, mac: mac, anyUnverified: anyUnverified, viewerRank: viewerRank) == words,
                                "\(cause.logText)")
                    }
                    if !ownSentences.contains(cause) { #expect(words == "The pair stopped (\(cause.logText))", "\(cause.logText)") }
                    #expect(!words.contains("no reason given") && !words.hasPrefix("The coordinator"), "\(cause.logText): \(words)")
                    for others in ["isn't verified by Apple", "isn't connected to Darkbloom", "run different Darkbloom builds",
                                   "The clock of"] {
                        #expect(!words.contains(others), "\(cause.logText): \(words)")
                    }
                    #expect(words.contains("is busy with other work") == (cause == .guidance(.modelBusy)), "\(cause.logText): \(words)")
                    #expect(Words.isMemoryShort(words) == [.memoryRefused(Self.refusal), .guidance(.memoryGateRefused)].contains(cause),
                            "\(cause.logText): \(words)")
                    if let other = said[words], other != cause { Issue.record("\(other.logText) and \(cause.logText) both read: \(words)") }
                    said[words] = cause
                }
            }
        }
        #expect(Words.words(.memoryRefused(Self.refusal), mac: Self.macs[0], viewerRank: 1)
                == "This Mac doesn't have enough free memory for its share (needs 73.6 GiB, has 68.2 GiB)")
        #expect(Words.words(.memoryRefused(Self.refusal), mac: Self.macs[0], viewerRank: 0)
                == "The other Mac doesn't have enough free memory for its share (needs 73.6 GiB, has 68.2 GiB)")
    }

    /// What mends each cause. Every cause is decided here, so a cause added without a decision does not compile.
    static func remedy(for cause: Cause) -> Words.StopRemedy? {
        switch cause {
        case .memoryRefused: return .freeMemory
        case .guidance(let code):
            switch code {
            case .memoryGateRefused: return .freeMemory
            case .deviceBusy: return .recoverDevice
            case .versionMismatch: return .updateBothMacs
            case .orphanedWiredMemory, .localProviderRunning, .followerNotConnected, .localNetworkDenied, .loginRejected,
                 .hostKeyUnknown, .hostIdentityChanged, .noMatchingHostKey, .addressUnresolved, .peerUnreachable, .bootstrapStalled,
                 .linkNotReady, .rdmaCompletionError, .collectiveStall, .rankLeaseExpired, .workerRuntimeUnverified,
                 .modelIdentityMismatch, .modelStageIncomplete, .planChanged, .unsupportedMode, .peerLost, .workerCrashed,
                 .peerTimeout, .launchInterrupted, .configurationInvalid, .cleanupUnresolved, .modelBusy, .listenerFailed,
                 .requestFailed, .runtimeError, .unknownFailure:
                return nil
            }
        case .didNotForm, .readinessLost, .firstRequestFailed, .memberStopping, .sessionEnded, .other: return nil
        }
    }

    /// The readers that hold only the words (the other Mac's status line, an outcome block) read each cause's sentence
    /// back to its remedy, on whichever Mac it is said and however the Mac is named, and read no other cause's so.
    @Test func theRemedyIsReadBackFromEveryCausesWords() {
        for mac in Self.macs {
            for cause in Self.everyCause {
                for viewerRank in Self.viewerRanks {
                    let words = Words.words(cause, mac: mac, viewerRank: viewerRank)
                    let remedy = Self.remedy(for: cause)
                    #expect(Words.stopRemedy(saidBy: words) == remedy, "\(cause.logText): \(words)")
                    #expect(Words.remedy(forReason: words) == remedy.map(Words.words), "\(cause.logText): \(words)")
                    // As the status line carries it and the outcome block titles it.
                    let read = Words.reason(inStatusLine: Words.statusLine(model: "Qwen 3.8 27B", reason: words))
                    #expect(read == words, "\(words)")
                }
            }
        }
        #expect(Set(Words.StopRemedy.allCases.map(Words.words)).count == Words.StopRemedy.allCases.count)
        // Two Macs on different releases bring their own remedies, naming the Mac to update: not the mismatch's.
        let split = ClusterOnboardingVersionSplit(thisVersion: "0.10.16", otherVersion: "0.10.15", other: Self.macs[2])
        for line in [split.title, split.reason, "The two Macs run different Darkbloom builds"] {
            #expect(Words.stopRemedy(saidBy: line) == nil && Words.remedy(forReason: line) == nil, "\(line)")
        }
    }

    /// The words a session says for how it ended reach the leading Mac in the other Mac's report of its fence
    /// (`leader lost: this Mac's committed session ended: <words>`): each is as it was, with the error after an early
    /// end as before. The same end is the cause the leading Mac's own line says.
    @Test func theSessionsOwnWordsAreAsTheyWere() {
        let words: [(Cause.SessionEnd, String)] = [
            (.coordinatorCancelled, "the coordinator cancelled it"),
            (.grantExpired, "the coordinator's grant expired"),
            (.connectionClosed, "its connection to the coordinator closed"),
            (.connectionStayedClosed, "its connection to the coordinator stayed closed past the grace"),
            (.couldNotServe, "this Mac could not serve it"),
            (.endedEarly, "it ended early"),
            (.ownerInvalidated, "its owner was invalidated before the prelude completed"),
            (.memberStopping, "this Mac's member is stopping"),
            (.ownerEndedCleanly, "its owner ended cleanly"),
        ]
        #expect(words.map(\.0) == Cause.SessionEnd.allCases)
        for (end, said) in words {
            #expect(end.words == said && NativePairSessionEnd(end).words == said && NativePairSessionEnd(end).cause == end)
        }
        let error = ClusterPairSlotError.notServing("the pair did not become ready")
        #expect(NativePairSessionEnd(.endedEarly, error: error).words == "it ended early: \(error)")
        #expect(NativePairSessionEnd(.couldNotServe, error: error).words == "this Mac could not serve it: \(error)")
        #expect(NativePairSessionEnd(.couldNotServe, error: error).cause == .couldNotServe)
    }
}
