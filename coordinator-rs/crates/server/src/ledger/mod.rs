//! Durable, replay-safe financial services.

mod deposit;
mod lifecycle;
mod release;
mod release_terminal;
mod reserve;
mod resize;
mod retry_precontent;
mod review;
mod settle;
pub mod types;
mod withdrawal;

use crate::{database::Database, db::ownership::DurableDatabase};

pub use review::review_resolution_operation;
pub use types::*;

/// Concrete durable ledger service. It is intentionally not hidden behind a
/// trait: all production mutations share the same SQLx and ownership behavior.
#[derive(Clone, Debug)]
pub struct LedgerService {
    pub(crate) db: DurableDatabase,
}

impl LedgerService {
    #[must_use]
    pub fn new(database: Database) -> Self {
        Self {
            db: DurableDatabase::new(database),
        }
    }
}
