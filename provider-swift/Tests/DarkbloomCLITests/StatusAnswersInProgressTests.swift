import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// `darkbloom status` lists the answers a Mac is writing, under the serving block (QWEN36-STUCK §5: a provider took
/// two long answers for a hang, because the served counters move only when an answer finishes).
@Suite("Status: answers in progress")
struct StatusAnswersInProgressTests {
    static let model = "qwen3.6-35b-a3b-vl-mtp-mxfp8"
    static let two = [
        DaemonState.RunningRequest(model: model, ref: "aea3a020", elapsedSeconds: 795, outputTokens: 30_800,
                                   tokensPerSecond: 38.74),
        DaemonState.RunningRequest(model: model, ref: "07b64cf9", elapsedSeconds: 794, outputTokens: 30_790,
                                   tokensPerSecond: 39.3),
    ]

    private func state(_ running: [DaemonState.RunningRequest]?, writtenAgo: Double = 2,
                       now: Double) throws -> DaemonState {
        var state = try CLICommandSandbox.runningState(now: now, writtenAt: now - writtenAgo)
        state.runningRequests = running
        return state
    }

    @Test func eachRunningAnswerHasItsLineAndCreditsPostWhenItFinishes() throws {
        let now = Date().timeIntervalSince1970
        #expect(Status.runningRequestLines(state: try state(Self.two, now: now), now: now) == [
            "Answers in progress: 2",
            "  qwen3.6-35b-a3b-vl-mtp-mxfp8: 13m 17s, 30800 tokens so far, 38.7 tok/s (#aea3a020)",
            "  qwen3.6-35b-a3b-vl-mtp-mxfp8: 13m 16s, 30790 tokens so far, 39.3 tok/s (#07b64cf9)",
            "  Credits post when a paid answer finishes; requests to your own machine are free.",
        ])
    }

    @Test func anAnswerStillReadingItsPromptSaysSo() throws {
        let now = Date().timeIntervalSince1970
        let reading = DaemonState.RunningRequest(model: "gemma-4-26b", ref: "0a1b2c3d", elapsedSeconds: 4,
                                                 outputTokens: 0, tokensPerSecond: nil)
        #expect(Status.runningRequestLines(state: try state([reading], writtenAgo: 0, now: now), now: now) == [
            "Answers in progress: 1",
            "  gemma-4-26b: 4s, 0 tokens so far, reading the prompt (#0a1b2c3d)",
            "  Credits post when a paid answer finishes; requests to your own machine are free.",
        ])
    }

    @Test func nothingRunningAndOlderDaemonsPrintNothing() throws {
        let now = Date().timeIntervalSince1970
        #expect(Status.runningRequestLines(state: try state([], now: now), now: now).isEmpty)
        #expect(Status.runningRequestLines(state: try state(nil, now: now), now: now).isEmpty)
    }

    @Test func theJSONListsTheSameAnswers() throws {
        let now = Date().timeIntervalSince1970
        let data = try Status.statusJSON(state: try state(Self.two, now: now), alive: true, now: now,
                                         heartbeatIntervalSecs: 5, clusterPart: true)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["schema"] as? Int == 1)
        #expect(json["daemon"] as? String == "running")
        #expect(json["cluster_part"] as? Bool == true)
        #expect(json["note"] as? String
            == "Credits post when a paid answer finishes; requests to your own machine are free.")
        let answers = try #require(json["answers_in_progress"] as? [[String: Any]])
        #expect(answers.count == 2)
        let first = try #require(answers.first)
        #expect(Set(first.keys) == ["model", "ref", "elapsed_seconds", "output_tokens", "tokens_per_second"])
        #expect(first["model"] as? String == Self.model && first["ref"] as? String == "aea3a020")
        #expect(first["elapsed_seconds"] as? Double == 797)
        #expect(first["output_tokens"] as? Int == 30_800)
        #expect(first["tokens_per_second"] as? Double == 38.7)
    }

    @Test func theJSONOfAStoppedOrWedgedDaemon() throws {
        let now = Date().timeIntervalSince1970
        let stopped = try #require(JSONSerialization.jsonObject(with: try Status.statusJSON(
            state: nil, alive: false, now: now, heartbeatIntervalSecs: 5, clusterPart: false)) as? [String: Any])
        #expect(stopped["daemon"] as? String == "not_running")
        #expect((stopped["answers_in_progress"] as? [Any])?.isEmpty == true)
        let wedged = try #require(JSONSerialization.jsonObject(with: try Status.statusJSON(
            state: try state(Self.two, writtenAgo: 600, now: now), alive: true, now: now,
            heartbeatIntervalSecs: 5, clusterPart: false)) as? [String: Any])
        #expect(wedged["daemon"] as? String == "stale")
    }
}
