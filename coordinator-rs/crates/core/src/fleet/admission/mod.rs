//! One pure admission operation (plan sections 11.1-11.4, 11.6, 11.7).
//!
//! [`admit`] performs, in order:
//!
//! 1. Hard eligibility gates (section 11.2) — typed, tallied per failure.
//! 2. Advisory warm/health filtering (transient, never authoritative).
//! 3. Scoring of the survivors (section 11.4, [`crate::fleet::scoring`]).
//! 4. A permit reservation *description* — the returned [`DispatchPermit`]
//!    tells the caller what to reserve in the [`crate::fleet::permits`]
//!    book; nothing is executed here.
//! 5. A typed decision: `Prepare`, `RetryAfter`, or `Reject`.
//!
//! There is no separate public preflight and committing reserve path; this
//! replaces the Go `QuickCapacityCheck` + `ReserveProviderEx` pair.
//!
//! Quarantine fail-open policy (section 11.6): if no healthy candidate
//! survives the gates but a quarantine-expired candidate exists, exactly one
//! half-open probe dispatch is offered (`DispatchPermit::is_probe`); all
//! other traffic gets `RetryAfter`.
//!
//! Siblings: [`candidate`] (request/candidate input types), [`gates`] (hard
//! eligibility gates), [`decision`] (permit and decision types), [`admit`]
//! (the composed operation).

mod admit;
mod candidate;
mod decision;
mod gates;

pub use admit::admit;
pub use candidate::{CandidateSnapshot, RequestTraits};
pub use decision::{
    AdmissionConfig, AdmissionDecision, CapacityReason, DispatchPermit, RejectionReason,
};
pub use gates::GateFailure;
