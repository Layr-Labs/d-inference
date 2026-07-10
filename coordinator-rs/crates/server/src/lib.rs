//! Darkbloom Rust coordinator server crate.
//!
//! Component ownership follows `docs/architecture/rust-coordinator-plan.md`
//! section 7. The seams between concurrently-developed components live in
//! [`contracts`] — that module is FROZEN during parallel development: no
//! component may edit it unilaterally.
//!
//! | Module | Authority (plan section) |
//! |---|---|
//! | [`http`] | Axum API adapter (§7.1) |
//! | [`request_task`] | one logical request (§7.2) |
//! | [`fleet`] | live fleet decision state (§7.3) |
//! | [`provider_session`] | one provider WebSocket + epoch (§7.4) |
//! | [`ledger`] | atomic idempotent money transactions (§7.5) |
//! | [`trust`] | attestation and signature verification (§7.6) |
//! | [`recovery`] | durable-state sweepers (§18.1) |

pub mod catalog;
pub mod config;
pub mod contracts;
pub mod db;
pub mod fleet;
pub mod http;
pub mod ledger;
pub mod ownership;
pub mod provider_session;
pub mod recovery;
pub mod request_task;
pub mod supervisor;
pub mod trust;
