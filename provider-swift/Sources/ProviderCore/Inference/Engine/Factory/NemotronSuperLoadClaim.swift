// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLLM
import MLXVLM

/// LOAD bytes of the installation and any embedded head, claimed before any
/// allocation. Both payloads stay resident. The installation's staging
/// (source copies, image mapping, backend allowance) is released when
/// `NemotronSuperInstallation.stage` returns, and the head's construction
/// arrays only exist after that, so the two transients never coexist once
/// the staging buffers have left MLX's cache: the claim then holds the larger
/// transient, not both.
enum NemotronSuperLoadClaim {
    enum Failure: Error, Equatable { case invalidQuote }

    /// Payloads plus the larger transient when `sequential`, else both
    /// transients.
    static func bytes(installation: NemotronSuperInstallation.LoadQuote,
                      head: NemotronSuperMTPModule.LoadQuote?, sequential: Bool) throws -> Int {
        try bytes(installationPayload: installation.payloadBytes, staging: installation.stagingBytes,
            headPayload: head?.payloadBytes ?? 0, construction: head?.constructionBytes ?? 0,
            sequential: sequential)
    }

    static func bytes(installationPayload: Int, staging: Int, headPayload: Int, construction: Int,
                      sequential: Bool) throws -> Int {
        guard [installationPayload, staging, headPayload, construction].allSatisfy({ $0 >= 0 }) else {
            throw Failure.invalidQuote
        }
        let transient = sequential ? max(staging, construction) : try sum(staging, construction)
        return try sum(installationPayload, headPayload, transient)
    }

    /// Whether the load may hand MLX's cached buffers back to the system
    /// between installation and head: never while a retained or closing
    /// native owner's GPU work may still use freed buffers (the same rule as
    /// the shared budget's reclaimer). Decided before the claim.
    static func mayReturnStagingBuffers() -> Bool {
        ProviderLoop.nativeProcessAllowsReclamation()
    }

    /// After the installation's last fenced epoch: returns its freed staging
    /// buffers to the system so the head's construction cannot stack on them.
    /// False (nothing done) when reclamation became unsafe since the claim;
    /// the caller then fails the load rather than exceed its claim.
    static func returnStagingBuffers(budget: GlobalKVCacheBudget) -> Bool {
        guard mayReturnStagingBuffers() else { return false }
        let activity = budget.serviceBudget.beginUnboundedActivity()
        defer { activity.finish() }
        MLX.Stream().synchronize()
        MLX.Memory.clearCache()
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
