// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLLM
import MLXLMCommon
import MLXVLM

/// Explicit opt-in text speculation for the unpublished Super local owner,
/// using the checkpoint's embedded head through the SDK assistant with exact
/// rectangular (default) or serial target verification. Off unless
/// `DARKBLOOM_NEMOTRON_SUPER_MTP` is exactly `1`; the coordinator must measure
/// it on the full model before any default changes. An owner with speculation
/// installed is text-only: media is refused.
enum NemotronSuperLocalMTP {
    static let enabledKey = "DARKBLOOM_NEMOTRON_SUPER_MTP"
    /// Draft depth `1`…`3`; a value above one is the deep-draft opt-in.
    /// `auto` lets the engine's marginal policy pick 0…3 each step from
    /// measured acceptance and round cost (rectangular verification only).
    static let depthKey = "DARKBLOOM_NEMOTRON_SUPER_MTP_DEPTH"
    /// `rectangular` (default): one exact captured target window per round;
    /// `serial`: one ordinary target step per column.
    static let verificationKey = "DARKBLOOM_NEMOTRON_SUPER_MTP_VERIFICATION"
    /// Unmeasured allocator/backend scratch admitted with every request's
    /// bounded assistant charge, on top of the SDK's explicit array quotes.
    static let backendScratchBytes = 256 << 20

    enum Failure: Error, Equatable { case invalidDepth, invalidVerification, loadQuote }

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
        typealias Verification = NemotronSuperMTPAssistant.Settings.Verification
        /// The fixed depth, or the largest depth the adaptive policy may pick.
        let depth: Int
        var verification: Verification = .rectangularExact
        /// The engine selects each step's depth up to `depth`; every emitted
        /// token is still target-verified, so greedy output is unchanged.
        var adaptive = false

        /// nil keeps the ordinary target-only owner. A malformed depth or
        /// verification fails the load rather than silently changing the
        /// measured configuration.
        static func resolve(environment: [String: String]) throws -> Setting? {
            guard environment[enabledKey]?.trimmingCharacters(in: .whitespaces) == "1" else {
                return nil
            }
            var depth = 1
            var adaptive = false
            if let raw = environment[depthKey]?.trimmingCharacters(in: .whitespaces) {
                if raw == "auto" {
                    depth = NemotronSuperMTPAssistant.Settings.maximumDepth
                    adaptive = true
                } else {
                    guard let value = Int(raw),
                        (1 ... NemotronSuperMTPAssistant.Settings.maximumDepth).contains(value)
                    else { throw Failure.invalidDepth }
                    depth = value
                }
            }
            let verification: Verification
            switch environment[verificationKey]?.trimmingCharacters(in: .whitespaces) {
            case nil, "rectangular"?: verification = .rectangularExact
            case "serial"?: verification = .serial
            default: throw Failure.invalidVerification
            }
            // Adaptive serial rounds can never beat plain decode.
            guard !adaptive || verification == .rectangularExact else { throw Failure.invalidDepth }
            return Setting(depth: depth, verification: verification, adaptive: adaptive)
        }
    }

    /// The loaded embedded head and its setting, transferred from the load
    /// transaction to the builder. The engine's drafter keeps it alive until
    /// native retirement.
    struct Head {
        let module: NemotronSuperMTPModule
        let setting: Setting
    }

    /// Engine inputs: the text-only target wrapper (the capture target for
    /// rectangular verification), its bound assistant and the fixed-depth
    /// configuration with the assistant's verification mode.
    struct Engine {
        let model: NemotronSuperMTPTextTarget
        let assistant: NemotronSuperMTPAssistant
        let config: CBv2MTPConfig
    }

    /// Serial verification serves one request; rectangular verification
    /// verifies up to `requests` in one captured window.
    static func validate(_ setting: Setting, requests: Int) throws {
        guard requests == 1 || setting.verification == .rectangularExact else {
            throw NemotronSuperLocalBridgeBuilder.Failure.invalidConcurrency
        }
    }

    /// `requests` above one verifies up to that many requests in one exact
    /// captured window, each committing its own accepted prefix.
    static func engine(
        for model: NemotronSuperModel, head: Head, maximumSequenceLength: Int, requests: Int = 1
    ) throws -> Engine {
        try validate(head.setting, requests: requests)
        let verification = head.setting.verification
        let target =
            verification == .rectangularExact
            ? try NemotronSuperMTPCaptureTarget(capturing: model, maximumRequests: requests)
            : NemotronSuperMTPTextTarget(model)
        let depth = head.setting.depth
        let assistant = try target.makeAssistant(
            head: head.module,
            settings: .init(
                maximumDraftTokens: depth, allowsDeepDrafts: depth > 1,
                maximumSequenceLength: maximumSequenceLength,
                backendScratchBytes: backendScratchBytes, verification: verification,
                maximumSpeculativeRows: requests))
        guard let mode = assistant.requiredVerificationMode else {
            throw Failure.invalidVerification
        }
        return Engine(
            model: target, assistant: assistant,
            config: CBv2MTPConfig(
                enabled: true, maxDraftTokens: depth, maxSpeculativeBatch: requests,
                fixedDraftTokens: head.setting.adaptive ? nil : depth, verificationMode: mode))
    }
}
