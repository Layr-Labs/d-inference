// Copyright © 2026 Eigen Labs.
//
// Pure decision function for the idle-timeout unload policy. Extracted
// out of `ProviderLoop` so the rule is unit-testable without
// constructing the full actor (which depends on Secure Enclave,
// coordinator client, security posture, etc.).

import Foundation

public enum IdleTimeoutPolicy {

    /// Should the loaded model be unloaded right now?
    ///
    /// Rules (all must be true):
    ///   1. A model is currently loaded (`hasLoadedModel`).
    ///   2. No requests are in flight (`hasInflight == false`).
    ///   3. `elapsed` since the last inference activity is at least the
    ///      configured `timeout`.
    ///
    /// Returning `true` means the caller should unload; the caller is
    /// responsible for actually doing the unload + clearing state.
    public static func shouldUnload(
        elapsed: Duration,
        timeout: Duration,
        hasInflight: Bool,
        hasLoadedModel: Bool
    ) -> Bool {
        guard hasLoadedModel else { return false }
        guard !hasInflight else { return false }
        return elapsed >= timeout
    }
}
