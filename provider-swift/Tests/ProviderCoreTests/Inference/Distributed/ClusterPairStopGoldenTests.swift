import Foundation
import Testing

@testable import ProviderCore

/// What a stopped pair's line carries and what each Mac says for it, recorded from the build that wrote the cause as
/// free text (`dev` at 0f78662e6b, after provider 0.10.16). The two Macs of a pair are often on different builds, and
/// the text between the parentheses of `Pair: stopped (…)` crosses the cable in the status both Macs read
/// (`ClusterServiceStatus.Child.pair`), so a build must keep writing these bytes and keep reading them the same way.
///
/// Every string here was printed by that build's code (`ClusterOnboardingPairReport`, `ClusterOnboardingNotServing`)
/// and is compared through the entry points that take text, which every build has. Do not edit a string to make a
/// change pass: a difference is a compatibility break between the two Macs.
@Suite("A stopped pair's text and words, byte for byte as the earlier build wrote and read them")
struct ClusterPairStopGoldenTests {
    typealias Report = ClusterOnboardingPairReport
    typealias Words = ClusterOnboardingNotServing
    static let mac = "one of the Macs"

    /// The guidance codes of a failed start's incident whose words are the code in "The pair stopped (…)".
    static let codesSaidAsTheyAre = [
        "orphaned_wired_memory", "local_provider_running", "follower_not_connected", "local_network_denied", "login_rejected",
        "host_key_unknown", "host_identity_changed", "no_matching_host_key", "address_unresolved", "peer_unreachable",
        "bootstrap_stalled", "link_not_ready", "rdma_completion_error", "collective_stall", "rank_lease_expired",
        "model_identity_mismatch", "model_stage_incomplete", "plan_changed", "unsupported_mode", "peer_lost", "worker_crashed",
        "peer_timeout", "launch_interrupted", "configuration_invalid", "cleanup_unresolved", "listener_failed", "request_failed",
        "runtime_error", "unknown_failure",
    ]

    /// The fixed words a retiring slot or a start without an incident writes.
    static let fixedWords = ["the pair did not form", "pair readiness lost", "its first request failed", "member stopping",
                             "committed start ended"]

    /// The three guidance codes whose words the earlier build got wrong (`ClusterPairStopCauseTests` says how): their
    /// text still reads back byte for byte, and their words are not part of this record.
    static let codesWithCorrectedWords = ["device_busy", "version_mismatch", "worker_runtime_unverified"]

    static let notVerified = "One of the Macs isn't verified by Apple yet; Darkbloom retries by itself within minutes. "
        + "Don't restart either Mac until then"
    static let memoryRemedy = "Quit apps on that Mac, then Retry; or change the model."

    /// Text, the words every screen says for it, and the remedy under those words.
    static let words: [(text: String, words: String, remedy: String?)] =
        codesSaidAsTheyAre.map { ($0, "The pair stopped (\($0))", nil) }
        + fixedWords.map { ($0, "The pair stopped (\($0))", nil) }
        + [
            ("memory_gate_refused", "One of the Macs lacks free memory for its share", memoryRemedy),
            ("model_busy", "One of the Macs is busy with other work", nil),
            // What the coordinator says when it refuses a pair, and text no build writes.
            ("liveness:trust_floor", notVerified, "Then choose Retry."),
            ("member rank 0 provider p: liveness:private_text", notVerified, "Then choose Retry."),
            ("app_attest_required (app_attest:lease)", notVerified, "Then choose Retry."),
            ("serves_model", "The coordinator doesn't let one of the Macs serve this model in a pair", nil),
            ("not_serving_model", "The coordinator doesn't let one of the Macs serve this model in a pair", nil),
            ("provider offline", "One of the Macs isn't connected to Darkbloom", nil),
            ("heartbeat stale", "One of the Macs isn't connected to Darkbloom", nil),
            ("not_logged_in", "One of the Macs isn't connected to Darkbloom", nil),
            ("idle:false", "One of the Macs is busy with other work", nil),
            ("Device_Busy", "One of the Macs is busy with other work", nil),
            ("release mismatch", "The two Macs run different Darkbloom builds", nil),
            ("build_hash", "The two Macs run different Darkbloom builds", nil),
            ("clock skew", "The clock of one of the Macs is off; turn on Set time automatically there", nil),
            ("x\u{1B}[2J", "The pair stopped (no reason given)", nil),
            (String(repeating: "a", count: 81), "The pair stopped (no reason given)", nil),
            ("memory_gate_refused: rank one needs 1 GiB, has 2 GiB", "One of the Macs lacks free memory for its share", memoryRemedy),
            ("", "The pair stopped ()", nil),
            ("committed start ended: the coordinator's grant expired",
             "The pair stopped (committed start ended: the coordinator's grant expired)", nil),
        ]

    /// A rank's load-gate refusal with its figures: the words name the Mac for the screen they reach.
    static let memoryWords: [(text: String, unknown: String, rankZero: String, rankOne: String)] = [
        ("memory_gate_refused: rank 1 needs 73.57 GiB, has 68.20 GiB",
         "One of the Macs doesn't have enough free memory for its share (needs 73.6 GiB, has 68.2 GiB)",
         "The other Mac doesn't have enough free memory for its share (needs 73.6 GiB, has 68.2 GiB)",
         "This Mac doesn't have enough free memory for its share (needs 73.6 GiB, has 68.2 GiB)"),
        ("memory_gate_refused: rank 0 needs 74 GiB, has 68 GiB",
         "One of the Macs doesn't have enough free memory for its share (needs 74.0 GiB, has 68.0 GiB)",
         "This Mac doesn't have enough free memory for its share (needs 74.0 GiB, has 68.0 GiB)",
         "The other Mac doesn't have enough free memory for its share (needs 74.0 GiB, has 68.0 GiB)"),
        // Two spaces: no build writes it, and the earlier build read it as the refusal all the same.
        ("memory_gate_refused: rank 1  needs 73.57 GiB, has 68.20 GiB",
         "One of the Macs doesn't have enough free memory for its share (needs 73.6 GiB, has 68.2 GiB)",
         "The other Mac doesn't have enough free memory for its share (needs 73.6 GiB, has 68.2 GiB)",
         "This Mac doesn't have enough free memory for its share (needs 73.6 GiB, has 68.2 GiB)"),
    ]

    static var everyText: [String] { words.map(\.text) + memoryWords.map(\.text) + codesWithCorrectedWords }

    /// The line a part writes, the text the status carries for it, and that text read back: the same bytes each way.
    @Test func everyStoppedTextReadsBackByteForByte() throws {
        #expect(Set(Self.everyText).count == Self.everyText.count, "a text is listed twice")
        for text in Self.everyText {
            let state = try #require(Report.latest(inLog: "earlier line\nPair: stopped (\(text))\n"), "\(text)")
            #expect(Report.text(state) == "stopped (\(text))", "\(text)")
            #expect(Report.state("stopped (\(text))") == state, "\(text)")
        }
        #expect(Report.startingLine == "Pair: starting")
        #expect(Report.servingLine(warmupSeconds: 0.8412) == "Pair: serving (first request in 0.84 s)")
        #expect(Report.servingLine(warmupSeconds: nil) == "Pair: serving")
        #expect(Report.latest(inLog: "Pair: starting\nPair: serving (first request in 0.84 s)\n").map(Report.text)
                == "serving (first request in 0.84 s)")
    }

    @Test func theWordsForEveryTextAreThoseOfTheEarlierBuild() {
        for row in Self.words {
            for viewerRank in [nil, 0, 1] as [Int?] {
                let said = Words.words(reason: row.text, mac: Self.mac, viewerRank: viewerRank)
                #expect(said == row.words, "\(row.text), read on rank \(String(describing: viewerRank))")
            }
            #expect(Words.remedy(forReason: row.words) == row.remedy, "\(row.text)")
        }
        for row in Self.memoryWords {
            #expect(Words.words(reason: row.text, mac: Self.mac) == row.unknown, "\(row.text)")
            #expect(Words.words(reason: row.text, mac: Self.mac, viewerRank: 0) == row.rankZero, "\(row.text)")
            #expect(Words.words(reason: row.text, mac: Self.mac, viewerRank: 1) == row.rankOne, "\(row.text)")
            for said in [row.unknown, row.rankZero, row.rankOne] {
                #expect(Words.remedy(forReason: said) == Self.memoryRemedy, "\(said)")
            }
        }
    }

    /// With both Macs verified by Apple, a trust word is the coordinator's own and is said as such; every other text
    /// reads as it does without that knowledge.
    @Test func aTrustWordOnTwoVerifiedMacsIsSaidAsTheCoordinators() {
        for row in Self.words {
            let unverified = Words.words(reason: row.text, mac: Self.mac, anyUnverified: true, viewerRank: 0)
            #expect(unverified == row.words, "\(row.text)")
            let verified = Words.words(reason: row.text, mac: Self.mac, anyUnverified: false, viewerRank: 0)
            let expected = row.words == Self.notVerified
                ? "The coordinator didn't accept the pair yet (\(row.text)); both Macs are verified by Apple, and it retries by itself"
                : row.words
            #expect(verified == expected, "\(row.text)")
        }
        for row in Self.memoryWords {
            for anyUnverified in [true, false] {
                #expect(Words.words(reason: row.text, mac: Self.mac, anyUnverified: anyUnverified, viewerRank: 0) == row.rankZero,
                        "\(row.text)")
            }
        }
    }
}
