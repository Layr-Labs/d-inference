//! Network and persistence adapters for the Rust coordinator.

pub mod app;
pub mod catalog;
pub mod config;
pub mod crypto;
pub mod database;
pub mod fleet;
mod mutation_fence;
pub mod ownership;
pub mod provider;
pub mod request;
pub mod runtime;
pub mod schema;
pub mod shutdown;
pub mod supervisor;
pub mod telemetry;
pub mod trust;
