//! Network and persistence adapters for the Rust coordinator.

pub mod app;
pub mod catalog;
pub mod config;
pub mod crypto;
pub mod database;
pub mod db;
pub mod fleet;
pub mod http;
pub mod ledger;
mod mutation_fence;
pub mod operator;
pub mod ownership;
pub mod pilot;
pub mod projection;
pub mod provider;
pub mod recovery;
pub mod request;
pub mod runtime;
pub mod schema;
pub mod shutdown;
pub mod supervisor;
pub mod telemetry;
pub mod trust;
