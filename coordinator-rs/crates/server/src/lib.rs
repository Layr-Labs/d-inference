//! Server library surface (Axum adapters land in Milestone 3).

pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
