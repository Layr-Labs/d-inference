// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLLM
import MLXLMCommon
import MLXVLM

/// Explicit opt-in text speculation for the unpublished Super local owner,
/// using the checkpoint's embedded head through the SDK's serial-verified
/// assistant. Off unless `DARKBLOOM_NEMOTRON_SUPER_MTP` is exactly `1`; the
/// coordinator must measure it on the full model before any default changes.
/// An owner with speculation installed is text-only: media is refused.
enum NemotronSuperLocalMTP {
    static let enabledKey = "DARKBLOOM_NEMOTRON_SUPER_MTP"
    /// Draft depth `1`…`3`; a value above one is the deep-draft opt-in.
    static let depthKey = "DARKBLOOM_NEMOTRON_SUPER_MTP_DEPTH"
    /// Unmeasured allocator/backend scratch admitted with every request's
    /// bounded assistant charge, on top of the SDK's explicit array quotes.
    static let backendScratchBytes = 256 << 20

    enum Failure: Error, Equatable { case invalidDepth, loadQuote }

    /// Header-derived head payload plus loader construction allowance; not a
    /// measured peak. Charged inside the owner's single pending LOAD claim.
    static func loadSupplementBytes(_ quote: NemotronSuperMTPModule.LoadQuote) throws -> Int {
        let (total, overflow) = quote.payloadBytes.addingReportingOverflow(
            quote.constructionBytes)
        guard !overflow, quote.payloadBytes > 0, quote.constructionBytes > 0 else {
            throw Failure.loadQuote
        }
        return total
    }

    struct Setting: Equatable, Sendable {
        let depth: Int

        /// nil keeps the ordinary target-only owner. A malformed depth fails
        /// the load rather than silently changing the measured configuration.
        static func resolve(environment: [String: String]) throws -> Setting? {
            guard environment[enabledKey]?.trimmingCharacters(in: .whitespaces) == "1" else {
                return nil
            }
            guard let raw = environment[depthKey]?.trimmingCharacters(in: .whitespaces) else {
                return Setting(depth: 1)
            }
            guard let depth = Int(raw),
                (1 ... NemotronSuperMTPAssistant.Settings.maximumDepth).contains(depth)
            else { throw Failure.invalidDepth }
            return Setting(depth: depth)
        }
    }

    /// The loaded embedded head and its setting, transferred from the load
    /// transaction to the builder. The engine's drafter keeps it alive until
    /// native retirement.
    struct Head {
        let module: NemotronSuperMTPModule
        let setting: Setting
    }

    /// Engine inputs: the text-only target wrapper, its bound assistant and
    /// the fixed-depth serial verification configuration.
    struct Engine {
        let model: NemotronSuperMTPTextTarget
        let assistant: NemotronSuperMTPAssistant
        let config: CBv2MTPConfig
    }

    static func engine(
        for model: NemotronSuperModel, head: Head, maximumSequenceLength: Int
    ) throws -> Engine {
        let target = NemotronSuperMTPTextTarget(model)
        let depth = head.setting.depth
        let assistant = try target.makeAssistant(
            head: head.module,
            settings: .init(
                maximumDraftTokens: depth, allowsDeepDrafts: depth > 1,
                maximumSequenceLength: maximumSequenceLength,
                backendScratchBytes: backendScratchBytes))
        return Engine(
            model: target, assistant: assistant,
            config: CBv2MTPConfig(
                enabled: true, maxDraftTokens: depth, maxSpeculativeBatch: 1,
                fixedDraftTokens: depth, verificationMode: .serialTarget))
    }
}
