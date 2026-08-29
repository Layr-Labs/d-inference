//! Single integration-test binary for `darkbloom-core`.
//!
//! Module map — what each module proves:
//! - `request::properties` — arbitrary event interleavings never violate the
//!   reducer invariants (plan §21 Milestone 1 exit gate; §9.2.3–9.2.11).
//! - `request::cancellation` — every cancellation-ladder rung (plan §13.1–13.6).
//! - `request::lifecycle` — happy path, hedging, funding race, terminal
//!   idempotency/conflict, ambiguous start, deadlines (plan §9.2, §10.6, §11.8).
//! - `fleet::properties` — calibration clamp, health quarantine discipline,
//!   permit accounting, hedge budget, admission soundness (plan §11, §9.2.10).
//! - `settlement::properties` — money conservation: reserve == charge + refund,
//!   exact splits, billing boundary, review flags (plan §9.3, §12.3, §13.6).
//! - `support` — shared fixtures and the deterministic request-machine driver.
//!
//! Proptest regression seeds live in `tests/proptest-regressions/<module>/<file>.txt`
//! (proptest's `SourceParallel` default: it walks up from the test source file to
//! this binary's `main.rs` directory and mirrors the module path in a sibling tree).

mod fleet;
mod request;
mod settlement;
mod support;
