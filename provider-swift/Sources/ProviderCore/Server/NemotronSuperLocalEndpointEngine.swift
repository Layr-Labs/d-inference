// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMServer

/// Unified local-endpoint engine for the managed Super slot. When the request
/// starts it acquires the slot through the provider's ordinary local path
/// (load gates and a local reservation), then streams through the owner's own
/// chat route. The reservation is released when that stream ends.
struct NemotronSuperLocalEndpointEngine: MLXServerEngine {
    struct Lease: Sendable {
        let owner: NemotronSuperSlotOwner
        let release: @Sendable () async -> Void
    }

    let body: Data
    let hasMedia: Bool
    /// The local application's prefix-cache partition.
    let cacheScope: String
    let acquire: @Sendable () async throws -> Lease
    /// Receives a `logprobs` request's entries (`LocalChatUploadResponder`).
    var logprobs: EngineV2LogprobsChannel? = nil

    func availableModels() async throws -> [MLXServerModel] { [] }
    func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse { throw unsupported() }
    func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse { throw unsupported() }
    func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse { throw unsupported() }
    private func unsupported() -> MultiModelBatchSchedulerEngineError {
        .requestRejected("the Super owner exposes only its bound chat request")
    }

    func streamChatCompletion(request: OpenAIChatCompletionRequest) async throws
        -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
        let lease = try await acquire()
        let inner: AsyncThrowingStream<MLXServerGenerationEvent, Error>
        do {
            // A local body has no authenticated boundary for schema metadata.
            inner = try await lease.owner.chatEngine(body: body, hasMedia: hasMedia, cacheScope: cacheScope,
                                                     trustsSchemaMetadata: false, logprobs: logprobs)
                .streamChatCompletion(request: request)
        } catch {
            await lease.release()
            throw error
        }
        let pair = AsyncThrowingStream<MLXServerGenerationEvent, Error>.makeStream()
        let relay = Task {
            do {
                for try await event in inner { pair.continuation.yield(event) }
                pair.continuation.finish()
            } catch { pair.continuation.finish(throwing: error) }
            await lease.release()
        }
        pair.continuation.onTermination = { _ in relay.cancel() }
        return pair.stream
    }
}
