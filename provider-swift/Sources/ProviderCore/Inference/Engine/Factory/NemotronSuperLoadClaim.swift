// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLLM
import MLXVLM

/// LOAD bytes of the installation and any embedded head, claimed before any
/// allocation. Both payloads stay resident. The installation's staging
/// (source copies, image mapping, backend allowance) is released when
/// `NemotronSuperInstallation.stage` returns, and the head's construction
/// arrays only exist after that, so once each phase's freed buffers have left
/// MLX's cache the two transients never coexist: the claim holds the larger,
/// not both. Nor does either coexist with serving: the room the same claim
/// reserves for the owner's lane, bank and KV floor stays unallocated until
/// the load has returned its transient buffers, so the transient only adds
/// what exceeds that room. Without reclamation (`sequential` false) both
/// transients are claimed in full, beside the serving room.
enum NemotronSuperLoadClaim {
    enum Failure: Error, Equatable { case invalidQuote }

    static func bytes(installation: NemotronSuperInstallation.LoadQuote,
                      head: NemotronSuperMTPModule.LoadQuote?, sequential: Bool,
                      servingBytes: Int = 0) throws -> Int {
        try bytes(installationPayload: installation.payloadBytes, staging: installation.stagingBytes,
            headPayload: head?.payloadBytes ?? 0, construction: head?.constructionBytes ?? 0,
            sequential: sequential, servingBytes: servingBytes)
    }

    /// Both payloads plus the transient beyond `servingBytes` (the serving
    /// room claimed beside it) when `sequential`; else both payloads and both
    /// transients.
    static func bytes(installationPayload: Int, staging: Int, headPayload: Int, construction: Int,
                      sequential: Bool, servingBytes: Int = 0) throws -> Int {
        guard [installationPayload, staging, headPayload, construction, servingBytes]
            .allSatisfy({ $0 >= 0 })
        else { throw Failure.invalidQuote }
        let transient = sequential
            ? max(0, max(staging, construction) - servingBytes) : try sum(staging, construction)
        return try sum(installationPayload, headPayload, transient)
    }

    /// Whether the load may hand MLX's cached buffers back to the system
    /// between installation and head: never while a retained or closing
    /// native owner's GPU work may still use freed buffers (the same rule as
    /// the shared budget's reclaimer). Decided before the claim.
    static func mayReturnStagingBuffers() -> Bool {
        ProviderLoop.nativeProcessAllowsReclamation()
    }

    /// After a phase's last fenced epoch: returns its freed transient buffers
    /// from MLX's cache to the system (`GlobalKVCacheBudget.returnCachedBuffers`),
    /// so the installation's staging cannot stack on the head's construction,
    /// nor either on live usage; also before a refused configuration is
    /// narrowed. False (nothing done) when reclamation became unsafe since
    /// the claim; before the head the caller then fails the load rather than
    /// exceed its claim.
    static func returnCachedLoadBuffers(budget: GlobalKVCacheBudget) -> Bool {
        guard mayReturnStagingBuffers() else { return false }
        budget.returnCachedBuffers()
        return true
    }

    private static func sum(_ values: Int...) throws -> Int {
        try values.reduce(0) { total, value in
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { throw Failure.invalidQuote }
            return next
        }
    }
}
