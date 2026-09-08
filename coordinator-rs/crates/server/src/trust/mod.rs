//! Pilot-scope trust verifier (plan §7.6).
//!
//! Verifies, on the blocking pool ([`tokio::task::spawn_blocking`] — P-256
//! and JSON canonicalization work must never run inside `FleetActor` or a
//! session read loop):
//!
//! - the registration attestation blob signature over the **raw preserved
//!   bytes** (plan §15.3: never deserialize and reserialize signed input
//!   before hashing — Swift escapes `/` as `\/`, so re-encoding breaks the
//!   digest);
//! - challenge nonce + timestamp signatures
//!   (`signing::verify_challenge_signature`);
//! - the canonical status signature (`signing::verify_status_signature`).
//!
//! # Pilot scope (explicit)
//!
//! `hardware` trust reuse and the MDM / MDA / APNs verification pillars are
//! **out of scope** for the pilot. The seam is a verdict enum
//! ([`TrustVerdict`](crate::contracts::TrustVerdict)) with
//! `HardwareTrusted` already present, so those verifiers slot in later by
//! emitting a higher verdict through the same epoch-fenced path; nothing
//! here needs to change shape. The highest verdict this module ever emits
//! is `SelfSigned` (a valid Secure Enclave attestation with the minimum
//! security posture).
//!
//! # Epoch fencing (plan §9.1.6)
//!
//! Every verification **mints its epoch when the verification starts**, from
//! one process-wide monotonic counter. The fleet applies a verdict only when
//! its epoch is strictly above the provider's current trust epoch, so a hard
//! downgrade issued after a slow verification began can never be reversed
//! when that older verification finally completes.
//!
//! Module layout: [`verifier`] (the epoch-minting entry points),
//! [`registration`] (attestation blob verification), [`challenge`]
//! (challenge/status signature verification), [`types`] (verdict shapes).

mod challenge;
mod registration;
#[cfg(test)]
mod testkit;
mod types;
mod verifier;

pub use types::{ChallengeExpectation, ChallengeVerdict, RegistrationVerdict};
pub use verifier::TrustVerifier;
