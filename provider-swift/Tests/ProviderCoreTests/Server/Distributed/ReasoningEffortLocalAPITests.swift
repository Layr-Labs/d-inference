import Foundation
import Hummingbird
import Logging
import NIOCore
import NIOEmbedded
import Testing
@testable import ProviderCore

/// One Mac's local API and a pair leader's take every reasoning effort a
/// client sends, and refuse one that is none of the names with a 400 that
/// names the field and the names. Journey 2a (B-J2-1): Hermes's
/// `reasoning_effort: "max"` got an untyped 400 "Invalid inference request."
/// from Qwen 3.8 27B on pair-2, so Hermes fell back to the user's paid provider.
/// Model-free (`ClusterAPIParityHarness.swift`); not a hardware result.
@Suite(.timeLimit(.minutes(3)))
struct ReasoningEffortLocalAPITests {
    /// The parity harness's Qwen 3.8 artifact, served under the registered
    /// build's ID as pair-2 serves it.
    static let qwen38: ParityFamily = {
        let base = ParityFamily.all.first { $0.name == "qwen3.8-27b" }!
        return ParityFamily(name: "qwen3.8-27b-registered", modelType: base.modelType,
            modelID: "EigenLabs/Qwen3.8-27B-4bit-mtp", configJSON: base.configJSON,
            generationJSON: base.generationJSON, eosToken: base.eosToken, harmony: base.harmony, plain: base.plain,
            tool: base.tool, stopString: base.stopString, long: base.long, json: base.json)
    }()

    struct Servers {
        let family: ParityFamily
        let solo: ParitySoloServer, pair: ParityClusterServer
        let soloTokenizer: EffortContextTokenizer, pairTokenizer: EffortContextTokenizer
        let client: URLSession

        static func start(_ family: ParityFamily, directory: URL) async throws -> Self {
            let script = ParityScript()
            script.set(family.plain)
            let soloTokenizer = EffortContextTokenizer(family.tokenizer)
            let pairTokenizer = EffortContextTokenizer(family.tokenizer)
            let solo = try await ParitySoloServer.start(family: family, directory: directory, script: script,
                                                        tokenizer: soloTokenizer)
            let pair = try await ParityClusterServer.start(family: family, directory: directory, tokenizer: pairTokenizer)
            return .init(family: family, solo: solo, pair: pair, soloTokenizer: soloTokenizer,
                         pairTokenizer: pairTokenizer, client: URLSession(configuration: .ephemeral))
        }

        func stop() async {
            client.invalidateAndCancel()
            await pair.stop()
            await solo.stop()
        }

        /// The pair answers with the family's plain script; it serves one
        /// request at a time, so this returns once it retired this one.
        func sendToPair(_ testCase: ParityCase) async throws -> ParityAnswer {
            let pair = pair, script = family.plain
            let reservations = pair.session.base.reserveCount
            let stop = ParityStopFlag()
            let driver = Task { await pair.drive(after: reservations, script: script, failure: false, stop: stop) }
            let answer: ParityAnswer
            do { answer = try await paritySend(port: pair.port, testCase, session: client) }
            catch { stop.set(); await driver.value; throw error }
            stop.set(); await driver.value
            let end = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < end {
                let held = await !pair.host.pins.isEmpty
                let queued = await !pair.host.waiting.isEmpty
                if !held && !queued { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            return answer
        }
    }

    /// The two fields a client names an effort in, and the body text naming `effort` in each.
    static let fields = ["reasoning_effort", "reasoning.effort"]

    static func control(_ field: String, _ effort: String) -> String {
        field == "reasoning_effort" ? #","reasoning_effort":"\#(effort)""# : #","reasoning":{"effort":"\#(effort)"}"#
    }

    /// Qwen 3.8's template renders `low`, `medium` and `xhigh`: `high` and
    /// `max` are served as `xhigh` and `minimal` as `low`, on one Mac and on
    /// the pair alike (tensor-parallel and pipeline pairs share this leader
    /// path); `none` switches thinking off.
    @Test func everyEffortIsServedOnOneMacAndOnAPair() async throws {
        let directory = try Self.qwen38.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let servers = try await Servers.start(Self.qwen38, directory: directory)
        let levels = ["none": "none", "minimal": "low", "low": "low", "medium": "medium", "high": "xhigh",
                      "xhigh": "xhigh", "max": "xhigh"]
        do {
            for (effort, level) in levels.sorted(by: { $0.key < $1.key }) {
                for field in Self.fields {
                    for stream in [false, true] {
                        let testCase = ParityCase("\(field)=\(effort) stream=\(stream)", body: ParityCase.chat(
                            servers.family.modelID, Self.control(field, effort), stream: stream))
                        let single = try await paritySend(port: servers.solo.port, testCase, session: servers.client)
                        let pair = try await servers.sendToPair(testCase)
                        for (place, answer, tokenizer) in [("one Mac", single, servers.soloTokenizer),
                                                           ("pair", pair, servers.pairTokenizer)] {
                            #expect(answer.status == 200, "\(place), \(testCase.name): \(answer)")
                            #expect(tokenizer.contexts.last?["reasoning_effort"] as? String == level,
                                    "\(place), \(testCase.name)")
                            #expect((tokenizer.contexts.last?["enable_thinking"] as? Bool == false) == (effort == "none"),
                                    "\(place), \(testCase.name)")
                        }
                    }
                }
            }
        } catch { await servers.stop(); throw error }
        await servers.stop()
    }

    /// An effort that is none of the names is answered before anything is
    /// rendered or reserved: 400, `invalid_reasoning_effort`, the field it
    /// came in, and the names this API takes.
    @Test func anUnknownEffortIsRefusedInWordsOnOneMacAndOnAPair() async throws {
        let directory = try Self.qwen38.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let servers = try await Servers.start(Self.qwen38, directory: directory)
        do {
            for field in Self.fields {
                for stream in [false, true] {
                    let testCase = ParityCase("\(field)=turbo stream=\(stream)", body: ParityCase.chat(
                        servers.family.modelID, Self.control(field, "turbo"), stream: stream), script: .none)
                    let single = try await paritySend(port: servers.solo.port, testCase, session: servers.client)
                    let pair = try await servers.sendToPair(testCase)
                    for (place, answer) in [("one Mac", single), ("pair", pair)] {
                        #expect(answer.status == 400, "\(place), \(testCase.name): \(answer)")
                        let body = try #require(answer.body.first.flatMap { Data($0.utf8) })
                        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                        let error = try #require(object["error"] as? [String: Any], "\(place): \(answer)")
                        #expect(error["type"] as? String == "invalid_request_error", "\(place)")
                        #expect(error["code"] as? String == "invalid_reasoning_effort", "\(place): \(answer)")
                        #expect(error["param"] as? String == field, "\(place): \(answer)")
                        #expect(error["message"] as? String
                            == "\(field) must be one of: none, minimal, low, medium, high, xhigh, max.",
                            "\(place): \(answer)")
                    }
                }
            }
            #expect(servers.soloTokenizer.contexts.isEmpty)
            #expect(servers.pairTokenizer.contexts.isEmpty)
            #expect(servers.pair.session.base.reserveCount == 0)
        } catch { await servers.stop(); throw error }
        await servers.stop()
    }

    /// Nemotron 3.5 Super reads both fields and doesn't choose between two that
    /// differ, even two names (`NemotronSuperPromptContract.controls(body:)`).
    /// Its local API refuses them as it refuses an unknown name, on text and
    /// media requests alike: 400, `invalid_reasoning_effort`, with `param` and
    /// the message naming both fields and the names, never the values sent.
    /// The same effort in both fields, in any spelling, is served.
    @Test func superRefusesTwoDifferentEffortsInWords() async throws {
        func body(_ top: String, _ nested: String) -> Data {
            Data(#"{"model":"m","messages":[{"role":"user","content":"hi"}],"reasoning_effort":"\#(top)","reasoning":{"effort":"\#(nested)"}}"#.utf8)
        }
        for (top, nested) in [("high", "max"), ("max", "high"), ("minimal", "medium"), ("turbo", "low")] {
            let error = try #require(throws: (any Error).self, "\(top)/\(nested)") {
                try NemotronSuperPromptContract.controls(body: body(top, nested))
            }
            for media in [false, true] {
                let (status, refusal) = try await Self.localAnswer(SuperHTTPErrors.map(error, media: media))
                let place = "\(top)/\(nested), media \(media)"
                #expect(status == .badRequest, "\(place)")
                #expect(refusal["type"] as? String == "invalid_request_error", "\(place)")
                #expect(refusal["code"] as? String == "invalid_reasoning_effort", "\(place): \(refusal)")
                #expect(refusal["param"] as? String == "reasoning_effort, reasoning.effort", "\(place): \(refusal)")
                #expect(refusal["message"] as? String == "reasoning_effort and reasoning.effort must be the same "
                    + "when both are sent, one of: none, minimal, low, medium, high, xhigh, max.", "\(place): \(refusal)")
            }
        }
        for (top, nested) in [("high", " HIGH "), ("none", "None")] {
            _ = try NemotronSuperPromptContract.controls(body: body(top, nested))
        }
    }

    /// The local API's answer (`CORSResponder`) to an error its engine threw.
    static func localAnswer(_ error: any Error) async throws -> (HTTPResponse.Status, [String: Any]) {
        let context = BasicRequestContext(source: ApplicationRequestContextSource(
            channel: EmbeddedChannel(), logger: Logger(label: "reasoning-effort")))
        let request = Request(head: .init(method: .post, scheme: "http", authority: "localhost",
                                          path: "/v1/chat/completions"), body: .init(buffer: ByteBuffer()))
        let response = try await CORSResponder(inner: EffortThrowingResponder(error: error))
            .respond(to: request, context: context)
        let body = EffortCollectedBody()
        try await response.body.write(body)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: Data(String(buffer: body.bytes).utf8)) as? [String: Any])
        return (response.status, try #require(envelope["error"] as? [String: Any]))
    }
}

private struct EffortThrowingResponder: HTTPResponder {
    typealias Context = BasicRequestContext
    let error: any Error
    func respond(to request: Request, context: Context) async throws -> Response { throw error }
}

private final class EffortCollectedBody: ResponseBodyWriter, @unchecked Sendable {
    var bytes = ByteBuffer()
    func write(_ buffer: ByteBuffer) async throws {
        var buffer = buffer
        bytes.writeBuffer(&buffer)
    }
    func finish(_ trailingHeaders: HTTPFields?) async throws {}
}
