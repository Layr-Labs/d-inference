//! Network and persistence adapters for the Rust coordinator.

pub mod app;
pub mod catalog;
pub mod config;
pub mod crypto;
pub mod database;
pub mod fleet;
pub mod http;
mod mutation_fence;
pub mod ownership;
pub mod pilot;
pub mod provider;
pub mod request;
pub mod runtime;
pub mod schema;
pub mod shutdown;
pub mod supervisor;
pub mod telemetry;
pub mod trust;
