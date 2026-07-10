//! Catalog snapshot loading and refresh (plan §8).
//!
//! The catalog (public alias → concrete build, pricing) is authoritative in
//! PostgreSQL and published as an atomically swapped in-memory snapshot
//! ([`crate::contracts::SharedCatalog`]). The request path NEVER reads the
//! database: only the background refresh task touches it, on a bounded,
//! jittered interval, and swaps whole snapshots.
//!
//! Sources, in order:
//!
//! 1. Legacy model tables (`model_registry`, `model_aliases`,
//!    `model_prices` with `account_id = 'platform'`) when present.
//! 2. An optional JSON config file for dev
//!    (`{"aliases": {...}, "prices": {"model": {"prompt_micro_per_mtok": n,
//!    "completion_micro_per_mtok": n}}}`).
//! 3. Go fallback default prices (`coordinator/payments/pricing.go`):
//!    $0.05 / $0.20 per 1M tokens.
//!
//! Precision note (reported for integration): the frozen contract
//! [`PriceCard`] is integer micro-USD **per token**, while legacy prices are
//! micro-USD **per million tokens** — sub-micro-USD-per-token rates round up
//! to 1 in the card. Exact per-M-token rates are preserved here in
//! [`ExactPrices`] and must be used when freezing terms (plan §12.4); the
//! `PriceCard` is display/quote material only.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use arc_swap::ArcSwap;
use serde::Deserialize;
use sqlx::{PgPool, Row};
use tokio_util::sync::CancellationToken;

use darkbloom_core::money::MicroUsd;

use crate::contracts::{CatalogSnapshot, PriceCard, SharedCatalog};

/// Go fallback defaults (micro-USD per 1M tokens),
/// `coordinator/payments/pricing.go`.
pub const DEFAULT_INPUT_PRICE_PER_MTOK: i64 = 50_000;
pub const DEFAULT_OUTPUT_PRICE_PER_MTOK: i64 = 200_000;

/// Base refresh interval; each tick adds deterministic jitter derived from
/// the snapshot version so refreshes never synchronize across restarts.
const REFRESH_INTERVAL: Duration = Duration::from_secs(30);
const REFRESH_JITTER_MAX: Duration = Duration::from_secs(7);

/// Exact per-million-token rates (micro-USD), keyed by concrete model —
/// the precision-preserving companion to the contract's per-token
/// [`PriceCard`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExactPrice {
    pub prompt_micro_per_mtok: i64,
    pub completion_micro_per_mtok: i64,
}

#[derive(Debug, Clone, Default)]
pub struct ExactPrices {
    pub version: u64,
    pub by_model: HashMap<String, ExactPrice>,
    /// Fallback for models without a configured price.
    pub default_price: ExactPrice,
}

impl Default for ExactPrice {
    fn default() -> Self {
        Self {
            prompt_micro_per_mtok: DEFAULT_INPUT_PRICE_PER_MTOK,
            completion_micro_per_mtok: DEFAULT_OUTPUT_PRICE_PER_MTOK,
        }
    }
}

pub type SharedExactPrices = Arc<ArcSwap<ExactPrices>>;

/// JSON shape of the dev catalog file.
#[derive(Debug, Deserialize)]
struct CatalogFile {
    #[serde(default)]
    aliases: HashMap<String, String>,
    #[serde(default)]
    prices: HashMap<String, CatalogFilePrice>,
}

#[derive(Debug, Deserialize)]
struct CatalogFilePrice {
    prompt_micro_per_mtok: i64,
    completion_micro_per_mtok: i64,
}

/// The catalog service: owns the shared snapshots and the refresh task.
pub struct Catalog {
    pool: PgPool,
    file: Option<PathBuf>,
    snapshot: SharedCatalog,
    exact: SharedExactPrices,
}

impl Catalog {
    /// Loads the initial snapshot (DB → file → defaults) and returns the
    /// service. Startup does not fail on catalog problems: an empty catalog
    /// serves no models but the process stays diagnosable.
    pub async fn bootstrap(pool: PgPool, file: Option<PathBuf>) -> Self {
        let catalog = Self {
            pool,
            file,
            snapshot: Arc::new(ArcSwap::from_pointee(CatalogSnapshot::default())),
            exact: Arc::new(ArcSwap::from_pointee(ExactPrices::default())),
        };
        catalog.refresh(1).await;
        catalog
    }

    pub fn snapshot_handle(&self) -> SharedCatalog {
        Arc::clone(&self.snapshot)
    }

    pub fn exact_prices_handle(&self) -> SharedExactPrices {
        Arc::clone(&self.exact)
    }

    /// Background refresh loop: bounded interval with jitter, atomic swap on
    /// success, previous snapshot retained on failure (plan §8).
    pub async fn run_refresh(self: Arc<Self>, cancel: CancellationToken) {
        let mut version: u64 = 2;
        loop {
            let jitter = Duration::from_millis(
                version
                    .wrapping_mul(2_654_435_761)
                    .checked_rem(REFRESH_JITTER_MAX.as_millis() as u64)
                    .unwrap_or(0),
            );
            tokio::select! {
                () = cancel.cancelled() => {
                    tracing::debug!("catalog refresh task stopping");
                    return;
                }
                () = tokio::time::sleep(REFRESH_INTERVAL + jitter) => {
                    self.refresh(version).await;
                    version += 1;
                }
            }
        }
    }

    /// One refresh attempt. Failures keep the previous snapshot.
    async fn refresh(&self, version: u64) {
        match self.load(version).await {
            Ok((snapshot, exact)) => {
                let models = snapshot.prices.len();
                let aliases = snapshot.aliases.len();
                self.snapshot.store(Arc::new(snapshot));
                self.exact.store(Arc::new(exact));
                tracing::debug!(version, models, aliases, "catalog snapshot swapped");
            }
            Err(err) => {
                tracing::warn!(error = %err, "catalog refresh failed; keeping previous snapshot");
            }
        }
    }

    async fn load(&self, version: u64) -> Result<(CatalogSnapshot, ExactPrices), CatalogError> {
        match self.load_from_db(version).await {
            Ok(loaded) => Ok(loaded),
            Err(CatalogError::LegacyTablesMissing) => {
                tracing::info!("legacy model tables absent; using catalog file / defaults");
                self.load_from_file(version)
            }
            Err(err) => Err(err),
        }
    }

    /// Reads the legacy model tables (shapes in
    /// `fixtures/sql/legacy_baseline.sql`).
    async fn load_from_db(
        &self,
        version: u64,
    ) -> Result<(CatalogSnapshot, ExactPrices), CatalogError> {
        let alias_rows = sqlx::query(
            "SELECT alias_id, desired_build FROM model_aliases \
             WHERE active AND desired_build <> ''",
        )
        .fetch_all(&self.pool)
        .await
        .map_err(classify)?;

        let model_rows = sqlx::query("SELECT id FROM model_registry")
            .fetch_all(&self.pool)
            .await
            .map_err(classify)?;

        let price_rows = sqlx::query(
            "SELECT model, input_price, output_price FROM model_prices \
             WHERE account_id = 'platform'",
        )
        .fetch_all(&self.pool)
        .await
        .map_err(classify)?;

        let mut aliases = HashMap::new();
        for row in &alias_rows {
            let alias: String = row.try_get("alias_id").map_err(CatalogError::Db)?;
            let build: String = row.try_get("desired_build").map_err(CatalogError::Db)?;
            aliases.insert(alias, build);
        }

        let mut exact_by_model = HashMap::new();
        for row in &price_rows {
            let model: String = row.try_get("model").map_err(CatalogError::Db)?;
            let input: i64 = row.try_get("input_price").map_err(CatalogError::Db)?;
            let output: i64 = row.try_get("output_price").map_err(CatalogError::Db)?;
            exact_by_model.insert(
                model,
                ExactPrice {
                    prompt_micro_per_mtok: input,
                    completion_micro_per_mtok: output,
                },
            );
        }

        // Every registered concrete model gets a price card (configured or
        // default) plus an identity alias so lookups by concrete id work.
        let mut prices = HashMap::new();
        for row in &model_rows {
            let id: String = row.try_get("id").map_err(CatalogError::Db)?;
            let exact = exact_by_model.get(&id).copied().unwrap_or_default();
            prices.insert(id.clone(), price_card(exact));
            aliases.entry(id.clone()).or_insert(id);
        }
        for (model, exact) in &exact_by_model {
            prices
                .entry(model.clone())
                .or_insert_with(|| price_card(*exact));
        }

        Ok((
            CatalogSnapshot {
                version,
                aliases,
                prices,
            },
            ExactPrices {
                version,
                by_model: exact_by_model,
                default_price: ExactPrice::default(),
            },
        ))
    }

    fn load_from_file(&self, version: u64) -> Result<(CatalogSnapshot, ExactPrices), CatalogError> {
        let Some(path) = &self.file else {
            // No file configured: empty catalog with default pricing.
            return Ok((
                CatalogSnapshot {
                    version,
                    ..CatalogSnapshot::default()
                },
                ExactPrices {
                    version,
                    ..ExactPrices::default()
                },
            ));
        };
        let parsed = read_catalog_file(path)?;

        let mut prices = HashMap::new();
        let mut exact_by_model = HashMap::new();
        for (model, price) in parsed.prices {
            let exact = ExactPrice {
                prompt_micro_per_mtok: price.prompt_micro_per_mtok,
                completion_micro_per_mtok: price.completion_micro_per_mtok,
            };
            prices.insert(model.clone(), price_card(exact));
            exact_by_model.insert(model, exact);
        }
        Ok((
            CatalogSnapshot {
                version,
                aliases: parsed.aliases,
                prices,
            },
            ExactPrices {
                version,
                by_model: exact_by_model,
                default_price: ExactPrice::default(),
            },
        ))
    }
}

fn read_catalog_file(path: &Path) -> Result<CatalogFile, CatalogError> {
    let raw = std::fs::read_to_string(path)
        .map_err(|e| CatalogError::File(path.to_path_buf(), e.to_string()))?;
    serde_json::from_str(&raw).map_err(|e| CatalogError::File(path.to_path_buf(), e.to_string()))
}

/// Per-token card from per-M-token rates: ceiling division so a nonzero
/// rate never displays as free (precision caveat in the module docs).
fn price_card(exact: ExactPrice) -> PriceCard {
    PriceCard {
        prompt_micro_per_token: MicroUsd::new(ceil_div_million(exact.prompt_micro_per_mtok)),
        completion_micro_per_token: MicroUsd::new(ceil_div_million(
            exact.completion_micro_per_mtok,
        )),
    }
}

fn ceil_div_million(v: i64) -> i64 {
    if v <= 0 {
        0
    } else {
        (v + 999_999) / 1_000_000
    }
}

#[derive(Debug, thiserror::Error)]
enum CatalogError {
    #[error("legacy model tables missing")]
    LegacyTablesMissing,
    #[error("catalog query failed: {0}")]
    Db(sqlx::Error),
    #[error("catalog file {0} unreadable: {1}")]
    File(PathBuf, String),
}

fn classify(err: sqlx::Error) -> CatalogError {
    match err.as_database_error().and_then(|db| db.code()).as_deref() {
        Some("42P01") => CatalogError::LegacyTablesMissing,
        _ => CatalogError::Db(err),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn price_card_rounds_up_nonzero_rates() {
        let card = price_card(ExactPrice {
            prompt_micro_per_mtok: DEFAULT_INPUT_PRICE_PER_MTOK,
            completion_micro_per_mtok: 2_000_000,
        });
        // 50_000 / 1M rounds up to 1 (never displays as free).
        assert_eq!(card.prompt_micro_per_token.get(), 1);
        assert_eq!(card.completion_micro_per_token.get(), 2);
    }

    #[test]
    fn catalog_file_parses() {
        let dir = std::env::temp_dir().join(format!("dbcat-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("mkdir");
        let path = dir.join("catalog.json");
        std::fs::write(
            &path,
            r#"{"aliases":{"qwen3-30b":"qwen3-30b-a3b-4bit"},
                "prices":{"qwen3-30b-a3b-4bit":{"prompt_micro_per_mtok":50000,"completion_micro_per_mtok":200000}}}"#,
        )
        .expect("write");
        let parsed = read_catalog_file(&path).expect("parse");
        assert_eq!(
            parsed.aliases.get("qwen3-30b").map(String::as_str),
            Some("qwen3-30b-a3b-4bit")
        );
        assert_eq!(
            parsed.prices["qwen3-30b-a3b-4bit"].completion_micro_per_mtok,
            200000
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
