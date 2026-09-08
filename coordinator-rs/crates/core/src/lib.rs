//! Pure domain logic for the Darkbloom Rust coordinator
//! (`docs/architecture/rust-coordinator-plan.md`).
//!
//! This crate owns:
//!
//! - [`ids`], [`money`], [`time`]: newtypes for identities, epochs, digests,
//!   micro-USD money, tokens, and milliseconds (plan 19.3).
//! - [`request`]: the request lifecycle reducer — attempts, deadlines,
//!   funding CAS, hedging, cancellation ladder, terminal disposition
//!   (plan 7.2, 9.2, 11.8, 13).
//! - [`fleet`]: admission, scoring, calibration, health, permits, hedge
//!   budget, and model presence (plan 11, 10.7).
//! - [`settlement`]: reservation provenance, frozen terms, conserving
//!   splits, and the billing boundary (plan 9.3, 12.3, 12.4, 13.6).
//! - [`provider_error`]: the typed provider error classes (plan 10.5).
//!
//! No I/O of any kind — no async, no clocks, no randomness. Every function
//! is deterministic in its inputs, so every invariant in plan section 9 is
//! property-testable in milliseconds.

pub mod fleet;
pub mod ids;
pub mod money;
pub mod provider_error;
pub mod request;
pub mod settlement;
pub mod time;
