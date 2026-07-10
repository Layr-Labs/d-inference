//! Pure domain logic for the Darkbloom coordinator.
//!
//! This crate owns:
//! - Newtypes for IDs, money, tokens, epochs, and digests.
//! - The request lifecycle state machine (one reducer).
//! - Reservation provenance math (total + withdrawable).
//! - Fleet admission: hard gates, advisory filtering, scoring, calibration,
//!   health state machine, prepare permits, and the hedge policy.
//!
//! No I/O of any kind. Everything is property-testable in milliseconds.
