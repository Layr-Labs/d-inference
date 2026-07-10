//! Ledger suites against a real ephemeral PostgreSQL cluster: money
//! invariants, spend-cap concurrency, and the recovery sweepers plus
//! ownership guard.

mod concurrency;
mod pg;
mod recovery;
