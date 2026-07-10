//! Trust verifier — epoch-fenced results (plan §7.6 / §9.1).
//!
//! Slow certificate work belongs on the blocking pool; this module holds the
//! reducer that applies verified evidence into FleetActor-facing trust state.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct TrustEpoch(pub u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TrustLevel {
    Untrusted,
    SelfSigned,
    Hardware,
    MdaVerified,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrustEvidence {
    pub provider_id: String,
    pub session_epoch: u64,
    pub trust_epoch: TrustEpoch,
    pub level: TrustLevel,
    pub challenge_fresh: bool,
    pub runtime_ok: bool,
    pub encrypted_transport: bool,
}

#[derive(Debug, Clone)]
pub struct TrustState {
    pub level: TrustLevel,
    pub trust_epoch: TrustEpoch,
    pub challenge_fresh: bool,
    pub runtime_ok: bool,
    pub encrypted_transport: bool,
}

impl Default for TrustState {
    fn default() -> Self {
        Self {
            level: TrustLevel::Untrusted,
            trust_epoch: TrustEpoch(0),
            challenge_fresh: false,
            runtime_ok: false,
            encrypted_transport: false,
        }
    }
}

impl TrustState {
    /// Apply evidence only if it is not stale relative to the current trust epoch.
    /// Hard downgrades cannot be reversed by older in-flight verifier results.
    pub fn apply(&mut self, evidence: TrustEvidence) -> bool {
        if evidence.trust_epoch < self.trust_epoch {
            return false;
        }
        if evidence.trust_epoch == self.trust_epoch && evidence.level < self.level {
            // Same epoch cannot downgrade via stale path — require higher epoch.
            // Explicit hard downgrade must bump trust_epoch.
            return false;
        }
        self.trust_epoch = evidence.trust_epoch;
        self.level = evidence.level;
        self.challenge_fresh = evidence.challenge_fresh;
        self.runtime_ok = evidence.runtime_ok;
        self.encrypted_transport = evidence.encrypted_transport;
        true
    }

    pub fn hard_downgrade(&mut self, reason_epoch: TrustEpoch) {
        if reason_epoch < self.trust_epoch {
            return;
        }
        self.trust_epoch = TrustEpoch(reason_epoch.0 + 1);
        self.level = TrustLevel::Untrusted;
        self.challenge_fresh = false;
        self.runtime_ok = false;
        self.encrypted_transport = false;
    }

    pub fn publicly_routable(&self) -> bool {
        matches!(self.level, TrustLevel::Hardware | TrustLevel::MdaVerified)
            && self.challenge_fresh
            && self.runtime_ok
            && self.encrypted_transport
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stale_evidence_cannot_undo_downgrade() {
        let mut st = TrustState::default();
        assert!(st.apply(TrustEvidence {
            provider_id: "p".into(),
            session_epoch: 1,
            trust_epoch: TrustEpoch(1),
            level: TrustLevel::Hardware,
            challenge_fresh: true,
            runtime_ok: true,
            encrypted_transport: true,
        }));
        assert!(st.publicly_routable());
        st.hard_downgrade(TrustEpoch(1));
        assert!(!st.publicly_routable());
        // Older in-flight grant at epoch 1 must not restore trust.
        assert!(!st.apply(TrustEvidence {
            provider_id: "p".into(),
            session_epoch: 1,
            trust_epoch: TrustEpoch(1),
            level: TrustLevel::Hardware,
            challenge_fresh: true,
            runtime_ok: true,
            encrypted_transport: true,
        }));
        assert!(!st.publicly_routable());
    }
}
