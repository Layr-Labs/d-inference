//! Fenced SQLx access and durable read snapshots.

pub mod catalog;
pub mod ownership;

pub use ownership::DurableDatabase;
