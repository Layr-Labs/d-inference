use std::sync::Arc;

use darkbloom_coordinator_core::ids::ModelId;
use serde_json::Value;
use sqlx::FromRow;
use thiserror::Error;

use crate::{
    database::Database,
    db::ownership::DurableDatabase,
    ledger::types::{AccountId, LedgerAmount, Version},
};

/// One immutable model build and pricing observation loaded by one statement.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CatalogSnapshot {
    pub requested_model: Arc<str>,
    pub public_model: Arc<str>,
    pub concrete_model: ModelId,
    pub model_version: Arc<str>,
    pub pricing_version: Version,
    pub rounding_version: Version,
    pub maximum_context_tokens: u64,
    pub maximum_output_tokens: u64,
    pub input_micro_usd_per_million: LedgerAmount,
    pub output_micro_usd_per_million: LedgerAmount,
    pub capabilities: Vec<String>,
    pub runtime_parameters: Value,
}

/// Concrete SQLx-backed catalog loader.
#[derive(Clone, Debug)]
pub struct CatalogService {
    db: DurableDatabase,
}

impl CatalogService {
    #[must_use]
    pub fn new(database: Database) -> Self {
        Self {
            db: DurableDatabase::new(database),
        }
    }

    /// Loads alias resolution, active model version, and account/platform price
    /// in one READ COMMITTED PostgreSQL snapshot.
    pub async fn load(
        &self,
        requested_model: &str,
        account_id: &AccountId,
    ) -> Result<CatalogSnapshot, CatalogError> {
        validate_requested_model(requested_model)?;
        let authority = self.db.authority().map_err(CatalogError::Ledger)?;
        authority.ensure_healthy().map_err(CatalogError::Ledger)?;
        let row = self
            .db
            .bounded(
                sqlx::query_as_unchecked!(
                    CatalogRow,
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT 1
                        FROM public.coordinator_ownership
                        WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                    ),
                    resolved AS MATERIALIZED (
                        SELECT
                            aliases.alias_id AS public_model,
                            aliases.desired_build AS concrete_model
                        FROM public.model_aliases AS aliases
                        WHERE aliases.alias_id = $3
                          AND aliases.active
                          AND aliases.desired_build <> ''
                        UNION ALL
                        SELECT registry.id, registry.id
                        FROM public.model_registry AS registry
                        WHERE registry.id = $3
                          AND NOT EXISTS (
                              SELECT 1
                              FROM public.model_aliases
                              WHERE alias_id = $3 AND active
                          )
                    ),
                    price AS MATERIALIZED (
                        SELECT
                            prices.input_price,
                            prices.output_price,
                            (prices.xmin::TEXT)::BIGINT AS pricing_version
                        FROM public.model_prices AS prices
                        JOIN resolved ON resolved.concrete_model = prices.model
                        WHERE prices.account_id IN ($4, 'platform')
                          AND prices.input_price >= 0
                          AND prices.output_price >= 0
                        ORDER BY (prices.account_id = $4) DESC
                        LIMIT 1
                    )
                    SELECT
                        resolved.public_model,
                        resolved.concrete_model,
                        versions.version AS model_version,
                        price.pricing_version,
                        registry.max_context_length::BIGINT
                            AS maximum_context_tokens,
                        registry.max_output_length::BIGINT
                            AS maximum_output_tokens,
                        price.input_price,
                        price.output_price,
                        registry.capabilities,
                        registry.runtime_parameters
                    FROM authority
                    CROSS JOIN resolved
                    JOIN public.model_registry AS registry
                      ON registry.id = resolved.concrete_model
                    JOIN public.model_active_versions AS active
                      ON active.model_id = registry.id
                    JOIN public.model_versions AS versions
                      ON versions.id = active.model_version_id
                    CROSS JOIN price
                    WHERE registry.status IN ('active', 'beta')
                      AND versions.status = 'ready'
                      AND versions.id > 0
                      AND registry.max_context_length > 0
                      AND registry.max_output_length > 0
                    "#,
                    authority.owner_id(),
                    authority.epoch(),
                    requested_model,
                    account_id.as_str(),
                )
                .fetch_optional(self.db.pool()),
            )
            .await
            .map_err(CatalogError::Ledger)?;
        let Some(row) = row else {
            self.db
                .verify_authority(&authority)
                .await
                .map_err(CatalogError::Ledger)?;
            return Err(CatalogError::NotFound);
        };
        row.into_snapshot(requested_model)
    }
}

#[derive(Debug, FromRow)]
struct CatalogRow {
    public_model: String,
    concrete_model: String,
    model_version: String,
    pricing_version: i64,
    maximum_context_tokens: i64,
    maximum_output_tokens: i64,
    input_price: i64,
    output_price: i64,
    capabilities: Vec<String>,
    runtime_parameters: Value,
}

impl CatalogRow {
    fn into_snapshot(self, requested_model: &str) -> Result<CatalogSnapshot, CatalogError> {
        let maximum_context_tokens = u64::try_from(self.maximum_context_tokens)
            .map_err(|_| CatalogError::Corrupt("negative model context"))?;
        let maximum_output_tokens = u64::try_from(self.maximum_output_tokens)
            .map_err(|_| CatalogError::Corrupt("negative model output limit"))?;
        Ok(CatalogSnapshot {
            requested_model: Arc::from(requested_model),
            public_model: Arc::from(self.public_model),
            concrete_model: ModelId::new(self.concrete_model)
                .map_err(|_| CatalogError::Corrupt("invalid concrete model id"))?,
            model_version: Arc::from(self.model_version),
            pricing_version: Version::new(
                u64::try_from(self.pricing_version)
                    .map_err(|_| CatalogError::Corrupt("invalid model version"))?,
            )
            .map_err(|_| CatalogError::Corrupt("invalid model version"))?,
            rounding_version: Version::new(1).expect("one is a positive version"),
            maximum_context_tokens,
            maximum_output_tokens,
            input_micro_usd_per_million: LedgerAmount::from_i64(self.input_price)
                .map_err(|_| CatalogError::Corrupt("negative input price"))?,
            output_micro_usd_per_million: LedgerAmount::from_i64(self.output_price)
                .map_err(|_| CatalogError::Corrupt("negative output price"))?,
            capabilities: self.capabilities,
            runtime_parameters: self.runtime_parameters,
        })
    }
}

fn validate_requested_model(value: &str) -> Result<(), CatalogError> {
    if value.is_empty()
        || value.len() > 256
        || value.trim() != value
        || value.chars().any(char::is_control)
    {
        Err(CatalogError::InvalidModel)
    } else {
        Ok(())
    }
}

#[derive(Debug, Error)]
pub enum CatalogError {
    #[error("requested model id is invalid")]
    InvalidModel,
    #[error("model or account pricing snapshot was not found")]
    NotFound,
    #[error("catalog row violates an invariant: {0}")]
    Corrupt(&'static str),
    #[error(transparent)]
    Ledger(#[from] crate::ledger::types::LedgerError),
}
