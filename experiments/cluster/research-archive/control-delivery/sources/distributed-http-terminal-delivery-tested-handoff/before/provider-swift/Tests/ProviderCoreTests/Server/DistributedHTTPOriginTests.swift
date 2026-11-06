import Foundation
import Hummingbird
import Logging
import MLXLMCommon
import NIOCore
import NIOEmbedded
import Testing
@testable import ProviderCore

@Suite(.timeLimit(.minutes(1)))
struct DistributedHTTPOriginTests {
    private let publicModelID = "local/Verified-Example"
    @Test func streamingHandlerRetainsReceiptAcrossBodyAcquireAndTokenization() async throws {
        let policy = try DistributedFirstTokenBudgetPolicy(
            baseMilliseconds: 10_000, millisecondsPerInputToken: 1)
        let result = try await runHTTP(policy: policy, bodyDelay: .milliseconds(25))
        let origin = try #require(result.capture.receivedAt)
        let context = try #require(result.context)
        #expect(context.generationDeadline == origin.advanced(by: .seconds(30)))
        #expect(context.firstTokenDeadline == origin.advanced(by: .milliseconds(10_003)))
        #expect(origin <= result.capture.instant("body")!)
        #expect(result.capture.instant("bodyReady")! <= result.capture.instant("acquire")!)
        #expect(result.capture.instant("acquire")! < result.capture.instant("tokenize")!)
        #expect(result.status == .ok && result.reservations == 1)
        #expect(result.capture.output.contains("t4") && result.capture.output.contains("[DONE]"))
        #expect(result.capture.releaseCount == 1)
        #expect(DistributedRequestOrigin.current == nil)
    }

    @Test func delayedBodyExhaustsExplicitBudgetWithoutNativeReservation() async throws {
        let policy = try DistributedFirstTokenBudgetPolicy(
            baseMilliseconds: 20, millisecondsPerInputToken: 0)
        let result = try await runHTTP(policy: policy, bodyDelay: .milliseconds(60))
        #expect(result.status == .serviceUnavailable)
        #expect(result.reservations == 0 && result.context == nil)
        #expect(result.capture.output.contains("error"))
        #expect(!result.capture.output.contains("data:"))
        #expect(result.capture.releaseCount == 1)
        #expect(DistributedRequestOrigin.current == nil)
    }

    @Test func absentPolicyKeepsFirstTokenDeadlineAbsent() async throws {
        let result = try await runHTTP(policy: nil, bodyDelay: .milliseconds(40))
        let context = try #require(result.context)
        #expect(context.firstTokenDeadline == nil)
        #expect(context.generationDeadline == result.capture.receivedAt!.advanced(by: .seconds(30)))
        #expect(result.status == .ok && result.capture.releaseCount == 1)
    }

    @Test func ordinarySoloSubmissionDoesNotUseDistributedOriginOrPolicy() async throws {
        let engine = HTTPOriginSoloEngine()
        let bridge = EngineV2Bridge(
            engine: engine, modelId: "solo", tokenizer: TokenizerHandle(DistributedTestTokenizer()),
            eosTokenIds: [], distributedFirstTokenBudgetPolicy: try .init(
                baseMilliseconds: 1, millisecondsPerInputToken: 0))
        let stream = try await bridge.submitTokenized(
            promptTokens: [1, 2, 3], request: .init(model: "solo", messages: [], max_tokens: 2),
            firstContentDeadline: nil,
            distributedRequestOrigin: ContinuousClock.now.advanced(by: .seconds(-600)))
        for await _ in stream {}
        #expect(engine.submissionCount == 1)
        await bridge.shutdown()
    }

    @Test func registryRejectsUnreadyOwnerAndOverflowBeforeTakingOwnership() throws {
        let owner = HTTPOriginOwner()
        owner.base.available = false
        #expect(throws: DistributedEngineError.unavailable) {
            _ = try DistributedEngineFactory.makeRegistryEntry(
                owner: owner, expectedIdentity: owner.base.identity, publicModelID: publicModelID, profile: profile(),
                tokenizer: TokenizerHandle(DistributedTestTokenizer()), eosTokenIDs: [99])
        }
        owner.base.available = true
        #expect(throws: DistributedFirstTokenBudgetError.overflow) {
            _ = try DistributedEngineFactory.makeRegistryEntry(
                owner: owner, expectedIdentity: owner.base.identity, publicModelID: publicModelID, profile: profile(),
                tokenizer: TokenizerHandle(DistributedTestTokenizer()), eosTokenIDs: [99],
                firstTokenBudgetPolicy: .init(baseMilliseconds: .max, millisecondsPerInputToken: 1))
        }
        #expect(owner.base.reserveCount == 0 && owner.base.shutdownCount == 0)
    }

    @Test func registryRejectsInvalidPublicRoutingIdentity() throws {
        let owner = HTTPOriginOwner()
        for invalid in ["", "space here", "newline\n", "delete\u{7f}", String(repeating: "a", count: 513)] {
            #expect(throws: DistributedEngineError.self) {
                _ = try DistributedEngineFactory.makeRegistryEntry(
                    owner: owner, expectedIdentity: owner.base.identity, publicModelID: invalid,
                    profile: profile(), tokenizer: TokenizerHandle(DistributedTestTokenizer()), eosTokenIDs: [99])
            }
        }
        #expect(owner.base.reserveCount == 0 && owner.base.shutdownCount == 0)
    }

    @Test func explicitEarlierContextCannotBeExtendedByFactoryPolicy() async throws {
        let owner = HTTPOriginOwner()
        let bridge = try DistributedEngineFactory.makeBridge(
            owner: owner, expectedIdentity: owner.base.identity, profile: profile(),
            tokenizer: TokenizerHandle(DistributedTestTokenizer()), eosTokenIDs: [99],
            firstTokenBudgetPolicy: .init(baseMilliseconds: 10_000, millisecondsPerInputToken: 1))
        let now = ContinuousClock.now
        let earlier = DistributedRequestDeadlineContext(
            generationDeadline: now.advanced(by: .seconds(10)),
            firstTokenDeadline: now.advanced(by: .seconds(2)))
        let stream = try await bridge.submitTokenized(
            promptTokens: [1, 2, 3], request: .init(model: owner.base.identity.modelID,
                messages: [], temperature: 0, max_tokens: 2),
            firstContentDeadline: nil, distributedDeadlineContext: earlier,
            distributedRequestOrigin: now.advanced(by: .seconds(-1)))
        owner.base.last.send(.token(4)); owner.base.last.send(.token(5)); owner.base.last.acknowledge()
        for await _ in stream {}
        #expect(owner.context == earlier)
        await bridge.shutdown()
    }

    private func profile() throws -> DistributedResidentExecutionProfile {
        try .init(id: "fabricated-greedy", vocabularySize: 100, maxPromptTokens: 16,
                  maxOutputTokens: 2, maxContextTokens: 18, requestTimeout: .seconds(30))
    }

    private func runHTTP(policy: DistributedFirstTokenBudgetPolicy?, bodyDelay: Duration) async throws
        -> (capture: HTTPOriginCapture, context: DistributedRequestDeadlineContext?,
            status: HTTPResponse.Status, reservations: Int) {
        let publicModelID = self.publicModelID
        let capture = HTTPOriginCapture(), owner = HTTPOriginOwner()
        let tokenizer = TokenizerHandle(HTTPOriginTokenizer(capture: capture))
        let entry = try DistributedEngineFactory.makeRegistryEntry(
            owner: owner, expectedIdentity: owner.base.identity, publicModelID: publicModelID, profile: profile(),
            tokenizer: tokenizer, eosTokenIDs: [99], firstTokenBudgetPolicy: policy)
        let bridge = try #require(entry.engineV2Bridge)
        #expect(entry.container == nil && !entry.isVLM && entry.visionGate == nil)
        let servedModelID = await bridge.modelId
        #expect(servedModelID == publicModelID && publicModelID != owner.base.identity.modelID)
        let application = makeLocalInferenceApplication(
            config: .init(), defaultMaxTokens: 2,
            acquire: { modelID in
                guard modelID == publicModelID else {
                    throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelID)
                }
                capture.mark("acquire")
                try await Task.sleep(for: .milliseconds(15))
                return .init(tokenizer: entry.tokenizer,
                    releaseToken: OneShotRelease(release: { _ in capture.release() },
                                                 modelId: publicModelID),
                    container: nil, isVLM: false, engineV2Bridge: bridge)
            },
            tokenizerProvider: { _ in .init(tokenizer: entry.tokenizer, modelType: nil) },
            availableModels: { [publicModelID] }, mtpSlots: { [] })
        let json = "{\"model\":\"\(publicModelID)\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"stream\":true,\"temperature\":0,\"max_tokens\":2}"
        let request = Request(
            head: .init(method: .post, scheme: "http", authority: "localhost", path: "/v1/chat/completions"),
            body: .init(asyncSequence: HTTPOriginBody(json: json, delay: bodyDelay, capture: capture)))
        let context = BasicRequestContext(source: ApplicationRequestContextSource(
            channel: EmbeddedChannel(), logger: Logger(label: "distributed-http-origin")))
        do {
            let response = try await application.responder.respond(to: request, context: context)
            if owner.base.reserveCount > 0 {
                owner.base.last.send(.token(4)); owner.base.last.send(.token(5)); owner.base.last.acknowledge()
            }
            try await response.body.write(HTTPOriginWriter(capture: capture))
            await bridge.shutdown()
            return (capture, owner.context, response.status, owner.base.reserveCount)
        } catch {
            if owner.base.reserveCount > 0 { owner.base.last.acknowledge() }
            await bridge.shutdown()
            throw error
        }
    }
}
