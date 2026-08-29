//! Shared harnesses for the `it` binary, compiled once and used across the
//! suite modules: `e2e` (full-stack Postgres + bootstrap app), `http`
//! (faked-seam router harness), `net` (raw-TCP server/client), `pg`
//! (ephemeral Postgres clusters), and `session` (WebSocket provider fakes).

pub mod e2e;
pub mod http;
pub mod net;
pub mod pg;
pub mod session;

/// Serializes wall-clock-sensitive tests (inter-chunk-gap and
/// elapsed-window assertions) that were calibrated when each suite ran as
/// its own sequential binary. In the single shared binary all suites run in
/// parallel threads, and a scheduler stall from a concurrent
/// Postgres-cluster boot could push a timing assertion past its bound; the
/// guard removes that interference instead of loosening the assertions.
/// (Async mutex: the guard is intentionally held across the test's awaits.)
static TIMING: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// Acquires the timing serialization guard for the duration of a test.
pub async fn timing_lock() -> tokio::sync::MutexGuard<'static, ()> {
    TIMING.lock().await
}
