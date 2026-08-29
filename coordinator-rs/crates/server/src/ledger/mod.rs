//! The ledger service: atomic, idempotent money transactions over SQLx
//! (plan §7.5, §12.3, §12.5–12.8).
//!
//! [`Ledger`] implements [`crate::contracts::LedgerFacade`] and
//! [`crate::contracts::ApiKeyStore`]. Transaction shapes mirror the validated
//! SQL patterns in `coordinator-rs/fixtures/sql/smoke_money_flow.sql`:
//!
//! - [`reserve`](crate::contracts::LedgerFacade::reserve) is ONE wire round
//!   trip — a single statement of data-modifying CTEs gated on the
//!   operation-key insert (plan §12.5).
//! - Every mutating statement compares the expected coordinator fencing epoch
//!   in the same transaction; zero affected rows means
//!   [`LedgerError::EpochFenced`](crate::contracts::LedgerError::EpochFenced)
//!   (plan §20).
//! - All money math delegates to [`darkbloom_core::settlement`]; nothing in
//!   this module reimplements provenance or split arithmetic.
//!
//! Module layout: `accounts` (legacy-TEXT ↔ typed account-id directory),
//! `error` (SQLSTATE mapping + bounded serialization retries), `reserve`,
//! `freeze` (resize+freeze and `mark_running`), `settle`, `release`
//! (release and `move_to_review`), `apikeys` (auth reads + TTL cache).

mod accounts;
mod apikeys;
mod error;
mod freeze;
mod release;
mod reserve;
mod settle;

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use sqlx::PgPool;

use darkbloom_core::ids::JobId;

use crate::contracts::{
    ApiKeyRecord, ApiKeyStore, LedgerError, LedgerFacade, ReleaseParams, ReserveOutcome,
    ReserveParams, ResizeFreezeParams, SettleOutcome, SettleParams,
};

pub use accounts::{account_id_for, AccountDirectory};
pub use apikeys::hash_key;
pub use error::{is_serialization_failure, map_sqlx};

/// The concrete ledger service. Cheap to clone-by-Arc; construct once in
/// `main` and share as `Arc<dyn LedgerFacade>` + `Arc<dyn ApiKeyStore>`.
pub struct Ledger {
    pub(crate) pool: PgPool,
    /// Legacy account id credited by the fee-projection worker (plan §12.6).
    pub(crate) platform_account: String,
    /// Current coordinator fencing epoch, shared from
    /// [`crate::ownership::OwnershipGuard::epoch_cell`]. Used by the facade
    /// methods that do not carry an explicit epoch (`mark_running`,
    /// `move_to_review`).
    pub(crate) epoch_cell: Arc<AtomicU64>,
    pub(crate) accounts: AccountDirectory,
    pub(crate) key_cache: apikeys::KeyCache,
}

impl Ledger {
    pub fn new(pool: PgPool, platform_account: String, epoch_cell: Arc<AtomicU64>) -> Self {
        Self {
            pool,
            platform_account,
            epoch_cell,
            accounts: AccountDirectory::new(),
            key_cache: apikeys::KeyCache::new(),
        }
    }

    /// The account directory used to translate typed account ids back to
    /// legacy TEXT ids. Components that derive an
    /// [`darkbloom_core::ids::AccountId`] from a wire/legacy string (provider
    /// registration beneficiaries, auth) must register the mapping here so
    /// `reserve`/`resize_freeze` can write the legacy projections.
    pub fn accounts(&self) -> &AccountDirectory {
        &self.accounts
    }

    /// Invalidate every cached API-key auth result (generation bump — mirrors
    /// the Go `invalidateAllAPIKeyCache`).
    pub fn invalidate_api_key_cache(&self) {
        self.key_cache.invalidate_all();
    }

    pub(crate) fn current_epoch(&self) -> i64 {
        i64::try_from(self.epoch_cell.load(Ordering::Acquire)).unwrap_or(i64::MAX)
    }

    /// The coordinator epoch this ledger fences on, as the typed newtype.
    pub fn coordinator_epoch(&self) -> darkbloom_core::ids::CoordinatorEpoch {
        darkbloom_core::ids::CoordinatorEpoch::new(self.epoch_cell.load(Ordering::Acquire))
    }

    /// The bounded pool, shared with the recovery workers (read scans and
    /// outbox writes; all money mutations go through the facade methods).
    pub fn pool(&self) -> &PgPool {
        &self.pool
    }
}

#[async_trait::async_trait]
impl LedgerFacade for Ledger {
    async fn reserve(&self, p: ReserveParams) -> Result<ReserveOutcome, LedgerError> {
        reserve::reserve(self, p).await
    }

    async fn resize_freeze(&self, p: ResizeFreezeParams) -> Result<(), LedgerError> {
        freeze::resize_freeze(self, p).await
    }

    async fn mark_running(&self, job: JobId) -> Result<(), LedgerError> {
        freeze::mark_running(self, job).await
    }

    async fn settle(&self, p: SettleParams) -> Result<SettleOutcome, LedgerError> {
        settle::settle(self, p).await
    }

    async fn release(&self, p: ReleaseParams) -> Result<(), LedgerError> {
        release::release(self, p).await
    }

    async fn move_to_review(&self, job: JobId, reason: String) -> Result<(), LedgerError> {
        release::move_to_review(self, job, reason).await
    }
}

#[async_trait::async_trait]
impl ApiKeyStore for Ledger {
    async fn validate(&self, token: &str) -> Option<ApiKeyRecord> {
        apikeys::validate(self, token).await
    }
}
