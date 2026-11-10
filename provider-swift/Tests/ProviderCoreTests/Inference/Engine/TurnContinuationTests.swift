// Copyright © 2026 Eigen Labs.
// Turn continuation: where the hidden request is cut, how the reply is rebuilt
// from a stream, and which streams start one.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("Turn continuation cells")
struct TurnContinuationCellsTests {
    /// Opens an assistant message with `100, 101` and closes it with `102`.
    private static let rule = CBv2CanonicalBoundaryRule(open: [100, 101], close: [[102]])
    private static let prompt = [1, 2, 3, 100, 101]

    @Test func commonPrefixLengthStopsAtTheFirstDifference() {
        #expect(TurnContinuationCells.commonPrefixLength([1, 2, 3], [1, 2, 4, 5]) == 2)
        #expect(TurnContinuationCells.commonPrefixLength([1, 2], [1, 2, 3]) == 2)
        #expect(TurnContinuationCells.commonPrefixLength([], [1]) == 0)
        #expect(TurnContinuationCells.commonPrefixLength([9], [1]) == 0)
    }

    // MARK: A slot with the resident bank

    @Test func theBankShapeEndsOnTheBoundaryThatClosesTheReply() {
        let cells = TurnContinuationCells(gridTokens: 8, boundaryRule: Self.rule, residentBank: true)
        // The reply, the token that closes it, and the next message's first token.
        let shared = Self.prompt + [7, 7, 7, 102, 1]
        #expect(cells.continuationTokens(source: Self.prompt, shared: shared) == Self.prompt + [7, 7, 7, 102])
    }

    @Test func theBankShapeTakesAGridMultiplePastTheLastBoundary() {
        let cells = TurnContinuationCells(gridTokens: 8, boundaryRule: Self.rule, residentBank: true)
        let shared = Self.prompt + [7, 7, 7, 102] + Array(repeating: 1, count: 8)
        #expect(shared.count == 17)
        #expect(cells.continuationTokens(source: Self.prompt, shared: shared) == Array(shared.prefix(16)))
    }

    @Test func theBankShapeWithoutARuleEndsOnAGridMultiple() {
        let cells = TurnContinuationCells(gridTokens: 4, boundaryRule: nil, residentBank: true)
        let source = Array(0 ..< 6)
        #expect(cells.continuationTokens(source: source, shared: Array(0 ..< 11)) == Array(0 ..< 8))
        // No grid multiple past the one this turn already reached.
        #expect(cells.continuationTokens(source: source, shared: Array(0 ..< 7)) == nil)
    }

    @Test func theBankShapeIsSkippedWhenTheTurnAlreadyEndedOnTheLastPosition() {
        let cells = TurnContinuationCells(gridTokens: 8, boundaryRule: Self.rule, residentBank: true)
        // The reply is not closed inside the known prefix.
        #expect(cells.continuationTokens(source: Self.prompt, shared: Self.prompt + [7, 7]) == nil)
        #expect(cells.continuationTokens(source: Self.prompt, shared: Self.prompt) == nil)
        #expect(cells.continuationTokens(source: Self.prompt, shared: []) == nil)
    }

    // MARK: A slot with the durable tier only

    @Test func theDurableShapeEndsOneTokenPastTheLastGridMultiple() {
        let cells = TurnContinuationCells(gridTokens: 4, boundaryRule: nil, residentBank: false)
        let source = Array(0 ..< 6)
        #expect(cells.continuationTokens(source: source, shared: Array(0 ..< 11)) == Array(0 ..< 9))
        #expect(cells.continuationTokens(source: source, shared: Array(0 ..< 9)) == Array(0 ..< 9))
    }

    @Test func theDurableShapeIsSkippedUntilTheReplyCrossesAGridMultiple() {
        let cells = TurnContinuationCells(gridTokens: 4, boundaryRule: nil, residentBank: false)
        let source = Array(0 ..< 6)
        // The tier keeps multiples below a prompt's last token: 4 is kept, 8 is not reached.
        #expect(cells.continuationTokens(source: source, shared: Array(0 ..< 8)) == nil)
        #expect(cells.continuationTokens(source: source, shared: Array(0 ..< 6)) == nil)
        #expect(cells.continuationTokens(source: source, shared: []) == nil)
    }

    @Test func theDurableShapeIgnoresMessageBoundaries() {
        let cells = TurnContinuationCells(gridTokens: 8, boundaryRule: Self.rule, residentBank: false)
        // A closed reply that stays inside the first cell leaves nothing to keep.
        #expect(cells.continuationTokens(source: Self.prompt, shared: Self.prompt + [7, 102, 1]) == nil)
        let long = Self.prompt + [7, 7, 7, 102] + Array(repeating: 1, count: 8)
        #expect(cells.continuationTokens(source: Self.prompt, shared: long) == Array(long.prefix(17)))
    }

    // MARK: Predictions that are not a follow-up of the turn

    @Test func aPredictionThatLeavesThePromptEarlyIsDropped() {
        let source = Array(0 ..< 12)
        let early = [0, 1] + Array(repeating: 99, count: 20)
        // The template re-rendered the last two tokens of the prompt.
        let tail = Array(0 ..< 10) + Array(repeating: 99, count: 10)
        let bank = TurnContinuationCells(gridTokens: 4, boundaryRule: nil, residentBank: true)
        #expect(bank.continuationTokens(source: source, shared: early) == nil)
        #expect(bank.continuationTokens(source: source, shared: tail) == tail)
        let durable = TurnContinuationCells(gridTokens: 4, boundaryRule: nil, residentBank: false)
        #expect(durable.continuationTokens(source: source, shared: early) == nil)
        #expect(durable.continuationTokens(source: source, shared: tail) == Array(tail.prefix(17)))
    }

    @Test func aSlotWithoutAGridHasNoContinuation() {
        for bank in [true, false] {
            let cells = TurnContinuationCells(gridTokens: 0, boundaryRule: Self.rule, residentBank: bank)
            #expect(cells.continuationTokens(source: Self.prompt, shared: Self.prompt + [7, 7, 7, 102, 1]) == nil)
        }
    }
}

@Suite("Turn continuation reply capture")
struct TurnReplyCaptureTests {
    private static func reply(
        stream: Bool, parser: ReasoningParserFormat, _ events: [MLXServerGenerationEvent]
    ) -> String? {
        var capture = TurnReplyCapture(stream: stream, reasoningParser: parser)
        for event in events { capture.observe(event) }
        return capture.finish()
    }

    private static let weather = ToolCall(function: .init(name: "weather", arguments: ["city": .string("Paris")]))

    @Test func plainContentIsJoined() {
        for stream in [true, false] {
            #expect(Self.reply(stream: stream, parser: .none, [.content("Hel"), .content("lo")]) == "Hello")
        }
    }

    @Test func aStreamedReplyLeavesItsReasoningOut() {
        let events: [MLXServerGenerationEvent] = [.content("<think>pl"), .content("an</thi"), .content("nk>Answer.")]
        #expect(Self.reply(stream: true, parser: .qwen3, events) == "Answer.")
        // The format decides: without one the tags are the client's content.
        #expect(Self.reply(stream: true, parser: .none, events) == "<think>plan</think>Answer.")
    }

    @Test func aThoughtThePromptOpenedIsReasoning() {
        // The scheduler seeds the open tag the prompt ended with.
        let events: [MLXServerGenerationEvent] = [.content("<think>"), .content("plan</think>"), .content("Answer.")]
        #expect(Self.reply(stream: true, parser: .qwen3, events) == "Answer.")
        #expect(Self.reply(stream: false, parser: .qwen3, events) == "Answer.")
    }

    @Test func aCompleteReplyIsSplitOnceAtTheEnd() {
        let events: [MLXServerGenerationEvent] = [.content("<think>plan</think>\n\n"), .content("Answer.")]
        #expect(Self.reply(stream: false, parser: .qwen3, events) == "Answer.")
    }

    @Test func nativeChannelsAreNotParsedAgain() {
        let events: [MLXServerGenerationEvent] = [
            .parsed(.init(content: "", reasoningContent: "plan")),
            .parsed(.init(content: "a </think> b", reasoningContent: nil)),
        ]
        #expect(Self.reply(stream: false, parser: .qwen3, events) == "a </think> b")
        #expect(Self.reply(stream: true, parser: .none, events) == "a </think> b")
    }

    @Test func aToolCallLeavesNoReply() {
        #expect(Self.reply(stream: true, parser: .none, [.content("Checking."), .toolCall(Self.weather)]) == nil)
        #expect(Self.reply(stream: false, parser: .none, [.toolCall(Self.weather), .content("Done.")]) == nil)
    }

    @Test func anEmptyAnswerLeavesNoReply() {
        #expect(Self.reply(stream: true, parser: .none, []) == nil)
        #expect(Self.reply(stream: false, parser: .none, [.content("")]) == nil)
        #expect(Self.reply(stream: true, parser: .qwen3, [.content("<think>only a plan</think>")]) == nil)
        #expect(Self.reply(stream: false, parser: .qwen3, [.content("<think>only a plan")]) == nil)
        #expect(Self.reply(stream: true, parser: .none, [.info(.init(
            promptTokens: 1, completionTokens: 0, promptTime: 0, generationTime: 0, stopReason: "stop"))]) == nil)
    }
}

/// What a scripted continuation saw: every render, every submission, and
/// whether the model pin had been released by then.
private final class ContinuationRecorder: @unchecked Sendable {
    struct Submission: Equatable, Sendable {
        var source: [Int]
        var shared: [Int]
    }

    private let lock = NSLock()
    private var renderedReplies: [String] = []
    private var submitted: [Submission] = []
    private var release = false
    private var renderedBeforeRelease = false
    private var launched: [Task<Void, Never>] = []

    var replies: [String] { lock.withLock { renderedReplies } }
    var submissions: [Submission] { lock.withLock { submitted } }
    var released: Bool { lock.withLock { release } }
    var renderedEarly: Bool { lock.withLock { renderedBeforeRelease } }

    func markReleased() { lock.withLock { release = true } }
    func recordRender(_ reply: String) {
        lock.withLock {
            renderedReplies.append(reply)
            if !release { renderedBeforeRelease = true }
        }
    }
    func recordSubmission(_ source: [Int], _ shared: [Int]) {
        lock.withLock { submitted.append(.init(source: source, shared: shared)) }
    }

    /// The source's `launch`: keeps the task so a test can wait for it.
    func launch(_ work: @escaping @Sendable () async -> Void) {
        let task = Task.detached { await work() }
        lock.withLock { launched.append(task) }
    }

    /// Waits for every continuation that was started and returns how many
    /// there were. The forwarder starts one before it ends the client's
    /// stream, so a stream that has ended has started all it will.
    func finishLaunches() async -> Int {
        let tasks = lock.withLock { launched }
        for task in tasks { await task.value }
        return tasks.count
    }

    /// For the source's own launch, which keeps no task to wait for.
    func waitForSubmission(seconds: Double = 10) async -> Submission? {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if let first = submissions.first { return first }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return submissions.first
    }
}

@Suite("Turn continuation source")
struct TurnContinuationSourceTests {
    static let prompt = [1, 2, 3, 100, 101]
    static let close = 102
    static let userOpen = 103

    static func encode(_ text: String) -> [Int] { text.utf8.map { 1_000 + Int($0) } }

    /// The prompt, the reply and its close, then the next user message.
    fileprivate static func source(
        _ recorder: ContinuationRecorder, stream: Bool = true, parser: ReasoningParserFormat = .none,
        failing: Bool = false, recordsLaunch: Bool = true
    ) -> TurnContinuationSource {
        var source = TurnContinuationSource(
            promptTokens: prompt, stream: stream, reasoningParser: parser,
            render: { reply, probe in
                recorder.recordRender(reply)
                if failing { throw CancellationError() }
                return prompt + encode(reply) + [close, userOpen] + encode(probe)
            },
            submit: { source, shared in recorder.recordSubmission(source, shared) })
        if recordsLaunch { source.launch = { work in recorder.launch(work) } }
        return source
    }

    @Test func theSharedPrefixStopsBeforeTheTokenThatMayMergeWithTheUsersText() throws {
        let recorder = ContinuationRecorder()
        let shared = try Self.source(recorder).sharedPrefix(reply: "ok")
        // `userOpen` is the last token both renders share; it is left out.
        #expect(shared == Self.prompt + Self.encode("ok") + [Self.close])
        #expect(recorder.replies == ["ok", "ok"])
    }

    @Test func startSubmitsThePromptAndTheSharedPrefix() async {
        let recorder = ContinuationRecorder()
        Self.source(recorder).start(reply: "ok")
        let launches = await recorder.finishLaunches()
        #expect(launches == 1)
        #expect(recorder.submissions == [
            .init(source: Self.prompt, shared: Self.prompt + Self.encode("ok") + [Self.close])
        ])
    }

    @Test func theSourcesOwnLaunchSubmitsOffTheCallersTask() async {
        let recorder = ContinuationRecorder()
        Self.source(recorder, recordsLaunch: false).start(reply: "ok")
        let submission = await recorder.waitForSubmission()
        #expect(submission == .init(source: Self.prompt, shared: Self.prompt + Self.encode("ok") + [Self.close]))
    }

    @Test func aRenderThatFailsSubmitsNothing() async {
        let recorder = ContinuationRecorder()
        Self.source(recorder, failing: true).start(reply: "ok")
        let launches = await recorder.finishLaunches()
        #expect(launches == 1)
        #expect(recorder.replies == ["ok"])
        #expect(recorder.submissions.isEmpty)
    }
}

#if DEBUG
/// The production forwarder over a scripted engine row decides which streams
/// start a continuation.
@Suite("Turn continuation stream hook")
struct TurnContinuationStreamTests {
    private typealias Fixture = TurnContinuationSourceTests

    private static let tools = """
        [{"type":"function","function":{"name":"get_weather","parameters":{"type":"object",
          "properties":{"location":{"type":"string"}},"required":["location"]}}}]
        """

    private static func stop(_ reason: String? = "stop") -> GenerationEvent {
        .info(promptTokens: 5, completionTokens: 2, tokensPerSecond: 1, finishReason: reason)
    }

    /// Runs `events` through the forwarder and returns what the client's
    /// stream carried, or the error it ended with.
    private static func run(
        _ events: [GenerationEvent], recorder: ContinuationRecorder, stream: Bool = true,
        parser: ReasoningParserFormat = .none, reasoningPrefix: String? = nil, withTools: Bool = false,
        continuation: Bool = true, matchedStop: String? = nil
    ) async -> Result<[MLXServerGenerationEvent], Error> {
        do {
            var request = OpenAIChatCompletionRequest(
                model: "gemma-4-26b-qat-4bit", messages: [.init(role: .user, content: .text("hi"))])
            var handler: BatchedToolStreamHandler?
            if withTools {
                request.tools = try JSONDecoder().decode([OpenAITool].self, from: Data(tools.utf8))
                request.stream = true
                request.streamToolCallDeltas = true
            }
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "gemma4")
            if withTools {
                handler = try ToolStreamPreparation.makeHandler(
                    request: request, prepared: prepared, modelType: "gemma4", streamToolCalls: true)
            }
            let upstream = AsyncStream<GenerationEvent> { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
            // The bridge records a matched stop sequence before the terminal.
            let usage = EngineV2RequestUsageSignal()
            usage.record(matchedStopSequence: matchedStop)
            let output = try MultiModelBatchSchedulerEngine(registryProvider: { [:] })._testMakeEventStream(
                upstream: upstream, cancelUpstream: {}, prepared: prepared,
                releaseBox: OneShotRelease(release: { _ in recorder.markReleased() }, modelId: "fixture"),
                reasoningPrefix: reasoningPrefix, toolHandler: handler, usageSignal: usage,
                turnContinuation: continuation
                    ? Fixture.source(recorder, stream: stream, parser: parser) : nil)
            var received: [MLXServerGenerationEvent] = []
            for try await event in output { received.append(event) }
            return .success(received)
        } catch {
            return .failure(error)
        }
    }

    private static func content(_ result: Result<[MLXServerGenerationEvent], Error>) -> String? {
        guard case .success(let events) = result else { return nil }
        return events.reduce(into: "") { text, event in
            if case .content(let piece) = event { text += piece }
        }
    }

    @Test func aReplyTheEngineStoppedStartsOneAfterTheRelease() async {
        let recorder = ContinuationRecorder()
        let result = await Self.run([.chunk("Hel"), .chunk("lo"), Self.stop()], recorder: recorder)
        #expect(Self.content(result) == "Hello")
        let launches = await recorder.finishLaunches()
        #expect(launches == 1)
        #expect(recorder.submissions == [
            .init(source: Fixture.prompt, shared: Fixture.prompt + Fixture.encode("Hello") + [Fixture.close])
        ])
        #expect(recorder.replies == ["Hello", "Hello"])
        #expect(recorder.released)
        #expect(!recorder.renderedEarly)
    }

    @Test func theReplyIsWhatTheClientKeepsNotItsReasoning() async {
        let recorder = ContinuationRecorder()
        // The prompt opened the thought; the forwarder seeds the parser with it.
        let result = await Self.run(
            [.chunk("plan</think>"), .chunk("Answer."), Self.stop()], recorder: recorder, parser: .qwen3,
            reasoningPrefix: "<think>")
        #expect(Self.content(result) == "<think>plan</think>Answer.")
        let launches = await recorder.finishLaunches()
        #expect(launches == 1)
        #expect(recorder.replies == ["Answer.", "Answer."])
    }

    @Test func aPlainReplyToARequestWithToolsStartsOne() async {
        let recorder = ContinuationRecorder()
        let result = await Self.run([.chunk("Sunny today."), Self.stop()], recorder: recorder, withTools: true)
        #expect(Self.content(result) == "Sunny today.")
        let launches = await recorder.finishLaunches()
        #expect(launches == 1)
        #expect(recorder.replies == ["Sunny today.", "Sunny today."])
    }

    @Test func aToolCallStartsNone() async throws {
        let recorder = ContinuationRecorder()
        let call = #"<|tool_call>call:get_weather{location:<|"|>Paris<|"|>}<tool_call|>"#
        let result = await Self.run(
            [.chunk("Checking.\n"), .chunk(call), Self.stop()], recorder: recorder, withTools: true)
        let events = try result.get()
        #expect(events.contains { if case .toolCallDelta = $0 { true } else { false } })
        let launches = await recorder.finishLaunches()
        #expect(launches == 0)
        #expect(recorder.replies.isEmpty)
        #expect(recorder.submissions.isEmpty)
    }

    @Test func aReplyCutByTheTokenLimitStartsNone() async {
        let recorder = ContinuationRecorder()
        let result = await Self.run([.chunk("Hello"), Self.stop("length")], recorder: recorder)
        #expect(Self.content(result) == "Hello")
        let launches = await recorder.finishLaunches()
        #expect(launches == 0)
        #expect(recorder.replies.isEmpty)
    }

    @Test func aReplyEndedByAStopSequenceStartsNone() async {
        // The engine reports "stop" for a matched stop sequence too.
        let recorder = ContinuationRecorder()
        let result = await Self.run([.chunk("Hello"), Self.stop()], recorder: recorder, matchedStop: "END")
        #expect(Self.content(result) == "Hello")
        let launches = await recorder.finishLaunches()
        #expect(launches == 0)
        #expect(recorder.replies.isEmpty)
        #expect(recorder.released)
    }

    @Test func aTerminalWithoutAnEngineReasonStartsNone() async {
        // A cancelled row reports usage with no reason; the client sees "stop".
        let recorder = ContinuationRecorder()
        let result = await Self.run([.chunk("Hello"), Self.stop(nil)], recorder: recorder)
        #expect(Self.content(result) == "Hello")
        let launches = await recorder.finishLaunches()
        #expect(launches == 0)
        #expect(recorder.replies.isEmpty)
    }

    @Test func aStreamThatEndsWithoutATerminalStartsNone() async {
        let recorder = ContinuationRecorder()
        _ = await Self.run([.chunk("Hello")], recorder: recorder)
        let launches = await recorder.finishLaunches()
        #expect(launches == 0)
        #expect(recorder.replies.isEmpty)
    }

    @Test func anEngineErrorStartsNone() async {
        let recorder = ContinuationRecorder()
        let result = await Self.run([.chunk("Hello"), .error("boom")], recorder: recorder)
        #expect(throws: (any Error).self) { try result.get() }
        let launches = await recorder.finishLaunches()
        #expect(launches == 0)
        #expect(recorder.replies.isEmpty)
    }

    @Test func anEmptyReplyStartsNone() async {
        let recorder = ContinuationRecorder()
        _ = await Self.run([Self.stop()], recorder: recorder)
        let launches = await recorder.finishLaunches()
        #expect(launches == 0)
        #expect(recorder.replies.isEmpty)
    }

    @Test func aRequestWithoutASourceStartsNone() async {
        let recorder = ContinuationRecorder()
        let result = await Self.run([.chunk("Hello"), Self.stop()], recorder: recorder, continuation: false)
        #expect(Self.content(result) == "Hello")
        let launches = await recorder.finishLaunches()
        #expect(launches == 0)
        #expect(recorder.replies.isEmpty)
        #expect(recorder.released)
    }
}
#endif
