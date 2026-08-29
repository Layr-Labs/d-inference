//! Attestation challenge round (plan §7.6): sent on registration and every
//! challenge interval, verified via the blocking-pool trust verifier, and
//! reduced into an epoch-fenced `TrustVerdict`.
//!
//! Freshness policy: the fleet stamps every applied non-`Untrusted`
//! verdict; a provider whose stamps stop (missed/failed challenges) simply
//! ages out of the challenge-freshness hard gate. There is no separate
//! timeout bookkeeping here — one pending challenge slot, replaced each
//! round (a reply to a replaced nonce is dropped, mirroring Go's tracker).

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use bytes::Bytes;
use rand::RngCore;

use darkbloom_protocol::json_v1::{AttestationChallengeMessage, AttestationResponseMessage};

use crate::contracts::{FleetCommand, TrustVerdict};
use crate::trust::ChallengeExpectation;

use super::writer::{OutFrame, SessionWrite};
use super::{SessionContext, SessionDeps};

#[derive(Default)]
pub(crate) struct ChallengeState {
    pending: Option<ChallengeExpectation>,
}

impl ChallengeState {
    /// Builds the next challenge frame and records the expectation. `None`
    /// when the provider has no verified SE key to answer with (pilot: its
    /// trust stays at the registration verdict).
    pub fn next_challenge(&mut self, ctx: &SessionContext) -> Option<SessionWrite> {
        ctx.se_public_key.as_ref()?;
        let mut nonce_bytes = [0u8; 32];
        rand::rngs::OsRng.fill_bytes(&mut nonce_bytes);
        let nonce = BASE64.encode(nonce_bytes);
        let timestamp = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);

        let frame = AttestationChallengeMessage {
            nonce: nonce.clone(),
            timestamp: timestamp.clone(),
            ..Default::default()
        };
        let encoded = serde_json::to_vec(&frame).ok()?;
        self.pending = Some(ChallengeExpectation { nonce, timestamp });
        Some(SessionWrite {
            frame: OutFrame::Text(Bytes::from(encoded)),
            on_wire: None,
        })
    }

    /// Verifies one `attestation_response` and forwards the epoch-fenced
    /// verdict to the fleet (reliable lane — trust intent is never dropped,
    /// plan §9.4.5).
    pub async fn handle_response(
        &mut self,
        ctx: &SessionContext,
        deps: &SessionDeps,
        response: AttestationResponseMessage,
    ) {
        let Some(se_key) = ctx.se_public_key.clone() else {
            tracing::debug!(provider = %ctx.provider, "attestation response without SE key");
            return;
        };
        let Some(expected) = self.pending.take() else {
            tracing::debug!(provider = %ctx.provider, "attestation response for no pending challenge");
            return;
        };
        if response.nonce != expected.nonce {
            // A reply to a superseded challenge: drop, matching Go's
            // tracker-miss path (the freshness window ages the trust stamp).
            tracing::debug!(provider = %ctx.provider, "attestation response nonce not pending");
            return;
        }

        let verdict = deps
            .trust
            .verify_challenge(se_key, ctx.provider_x25519_b64.clone(), expected, response)
            .await;
        match &verdict.verdict {
            TrustVerdict::Untrusted { reason } => {
                tracing::warn!(provider = %ctx.provider, reason, "challenge verification failed");
            }
            _ => {
                tracing::debug!(provider = %ctx.provider, bound = verdict.status_fields_bound,
                    "challenge verified");
            }
        }
        let _ = deps
            .fleet
            .commands
            .send(FleetCommand::TrustVerdict {
                provider: ctx.provider,
                trust_epoch: verdict.trust_epoch,
                verdict: verdict.verdict,
            })
            .await;
    }
}
