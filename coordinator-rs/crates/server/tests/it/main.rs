//! Single integration-test binary for `darkbloom-server` (cargo target
//! `it`). Every suite is a module below; harness code in [`support`] is
//! compiled exactly once and shared, and all tests run in one process in
//! parallel threads.
//!
//! Test map:
//!
//! | module    | what it proves                                                | real dependencies                |
//! |-----------|---------------------------------------------------------------|----------------------------------|
//! | `e2e`     | full-stack money trails: settlement, rejection, cancellation  | Postgres + HTTP + WebSocket      |
//! | `http`    | chat-completions flows through the real router, seams faked   | none (in-process router)         |
//! | `ledger`  | ledger/recovery/ownership invariants against a real database  | Postgres (ephemeral per test)    |
//! | `session` | provider-session wire protocol (v1/v2) and the fleet actor    | WebSocket over loopback TCP      |
//! | `net`     | socket-level posture: SSE latency, backpressure, HTTP/WS caps | raw loopback TCP                 |
//!
//! Postgres-backed tests each boot an isolated ephemeral cluster
//! (`support::pg`) and skip with a message when `initdb` is not on PATH.
//! Wall-clock-sensitive tests serialize behind `support::timing_lock()`.

mod support;

mod e2e;
mod http;
mod ledger;
mod net;
mod session;
