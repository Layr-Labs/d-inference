// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMServer

enum NemotronSuperSlotError: Error, Equatable {
    /// Only `ProviderLoop`'s managed load builds a Super slot.
    case managedLoadRequired
    /// An earlier Super owner retained native work; restart the process.
    case retainedFault
}

/// A loaded Super owner installed as a provider slot: the load transaction
/// that retains its native owners and charges until real retirement, and the
/// chat route shared with the qualification hook. `retire()` is the only way
/// to release it; a throw leaves everything retained for the process lifetime.
final class NemotronSuperSlotOwner: Sendable {
    let modelID: String
    let speculates: Bool
    let bridge: EngineV2Bridge
    let tokenizer: TokenizerHandle
    let sizing: SlotSizingSnapshot
    /// The configurations the LOAD gate weighed; the last is the one served.
    let fitAttempts: [NemotronSuperLocalLoad.FitAttempt]
    /// Held in the shared budget beside the KV grant until native retirement:
    /// the prefill lane, decode rows and MTP round work. Resident like
    /// weights to the re-slice and the heartbeat.
    let reservedBesideGrantBytes: Int
    /// The prefix bank's reservation, carved from the KV grant.
    let prefixBankBytes: Int
    private let transaction: NemotronSuperLocalLoad
    private let chat: NemotronSuperLocalImageHTTP

    init(transaction: NemotronSuperLocalLoad, bridge: EngineV2Bridge, tokenizer: TokenizerHandle,
         sizing: SlotSizingSnapshot, templateBytes: Data) async throws {
        do {
            chat = try await transaction.localImageHTTP(templateBytes: templateBytes)
        } catch {
            // Nothing has been served; retire the loaded owner before failing.
            try? await transaction.closeAfterDrain()
            throw error
        }
        fitAttempts = await transaction.fitAttempts
        (reservedBesideGrantBytes, prefixBankBytes) = await transaction.ownerReservations
        self.transaction = transaction
        self.bridge = bridge
        self.tokenizer = tokenizer
        self.sizing = sizing
        modelID = chat.modelID
        speculates = chat.speculates
    }

    /// One coordinator or local-endpoint request: text on the text binding,
    /// inline JPEG/PNG images or one inline video on the image binding
    /// (target-only when the owner speculates). Only the coordinator path
    /// trusts schema metadata (see `NemotronSuperRequestPlan`).
    func chatEngine(body: Data, hasMedia: Bool, cacheScope: String?,
                    trustsSchemaMetadata: Bool) -> any MLXServerEngine {
        chat.engine(body: body, hasMedia: hasMedia, cacheScope: cacheScope,
                    trustsSchemaMetadata: trustsSchemaMetadata)
    }

    /// The reference prompt length; see `NemotronSuperLocalImageHTTP`.
    func promptTokenCount(body: Data, trustsSchemaMetadata: Bool) -> Int {
        chat.promptTokenCount(body: body, trustsSchemaMetadata: trustsSchemaMetadata)
    }

    /// Rejects new chat work and joins it, then closes the owner: bindings,
    /// bridge, prefill lane, any prefix bank and the installation. Throws
    /// when native work did not retire; the transaction then retains every
    /// owner and charge.
    func retire() async throws {
        await chat.drain()
        try await transaction.closeAfterDrain()
    }
}

/// Builds a slot owner from a checkpoint directory under the provider's real
/// grant and budget. `pinnedCheckpoint` is the only production loader; tests
/// inject fixtures that run the same `NemotronSuperLocalLoad` transaction.
struct NemotronSuperSlotLoader: Sendable {
    struct Request: Sendable {
        let modelID: String
        let directory: URL
        let kvBytesCapacity: Int
        let admissionKVBytes: Int
        let defaultMaxTokens: Int
        let environment: [String: String]
        let budget: GlobalKVCacheBudget
        /// The loader's `physicalBytes`, which sized the plan's prefix bank.
        let physicalBytes: UInt64
    }

    /// Whether this loader stages the pinned checkpoint, and the machine
    /// memory its bank is sized for. The load plan and the builder size the
    /// prefix bank from these same two values.
    let pinned: Bool
    let physicalBytes: UInt64

    /// The per-token KV rate from metadata alone, before any re-slice; it
    /// also refuses an unpinned index, template or shard set early.
    let kvBytesPerToken: @Sendable (URL) throws -> Int
    let load: @Sendable (Request) async throws -> NemotronSuperSlotOwner

    init(pinned: Bool = true, physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
         kvBytesPerToken: @escaping @Sendable (URL) throws -> Int,
         load: @escaping @Sendable (Request) async throws -> NemotronSuperSlotOwner) {
        self.pinned = pinned
        self.physicalBytes = physicalBytes
        self.kvBytesPerToken = kvBytesPerToken
        self.load = load
    }

    /// Opens every shard against its pin, loads the pinned tokenizer and
    /// template, then claims, stages and builds through the transaction. A
    /// transaction left holding native work surfaces as `retainedFault`.
    static let pinnedCheckpoint = NemotronSuperSlotLoader(kvBytesPerToken: { directory in
        try NemotronSuperCheckpoint.Inputs(directory: directory).fp16KVBytesPerToken
    }) { request in
        let checkpoint = try await NemotronSuperCheckpoint.open(directory: request.directory)
        try Task.checkCancellation()
        // Sendable facts first: the shard source is sent to the transaction.
        let configData = checkpoint.inputs.configData, templateBytes = checkpoint.inputs.templateBytes
        let eosTokenIDs = checkpoint.inputs.eosTokenIDs
        let sizing = SlotSizingSnapshot(weightsBytes: checkpoint.tensorBytes,
            fp16KVBytesPerToken: checkpoint.inputs.fp16KVBytesPerToken,
            maxContextLength: NemotronSuperServingPolicy.contextTokens,
            defaultMaxTokens: request.defaultMaxTokens)
        let tokenizer = TokenizerHandle(try await LocalTokenizerLoader().load(from: request.directory))
        let transaction = NemotronSuperLocalLoad(budget: request.budget)
        do {
            let bridge = try await transaction.load(configData: configData,
                source: checkpoint.source, tokenizer: tokenizer, eosTokenIDs: eosTokenIDs,
                sizing: sizing, kvBytesCapacity: request.kvBytesCapacity,
                admissionKVBytes: request.admissionKVBytes,
                backendAllowanceBytes: NemotronSuperServingPolicy.backendAllowanceBytes,
                modelID: request.modelID, environment: request.environment,
                physicalBytes: request.physicalBytes)
            return try await NemotronSuperSlotOwner(transaction: transaction, bridge: bridge,
                tokenizer: tokenizer, sizing: sizing, templateBytes: templateBytes)
        } catch {
            if await transaction.phase == .retainedFault { throw NemotronSuperSlotError.retainedFault }
            throw error
        }
    }
}
