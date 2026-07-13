use darkbloom_coordinator_core::ids::ProviderId;
use serde_json::Value;
use sqlx::FromRow;
use thiserror::Error;
use uuid::Uuid;

use crate::{
    database::Database,
    db::catalog::{CatalogError, CatalogService, CatalogSnapshot},
    ledger::{AccountId, InputError, LedgerAmount, Version},
    pilot::{PaidBillingPolicy, PilotBilling, ProviderBeneficiaryEntry, ProviderPriceOverride},
    surface::identity::{AuthContext, AuthPrincipal},
};

const MAX_PROVIDER_BENEFICIARIES: i64 = 1_024;

#[derive(Clone, Debug)]
pub struct InferenceControl {
    database: Database,
    catalog: CatalogService,
}

#[derive(Clone)]
pub struct PreparedInference {
    pub catalog: CatalogSnapshot,
    pub billing: PilotBilling,
    pub api_key_limit_micro_usd: Option<i64>,
    pub api_key_controlled: bool,
    pub required_provider_id: Option<ProviderId>,
}

impl InferenceControl {
    #[must_use]
    pub fn new(database: Database) -> Self {
        Self {
            catalog: CatalogService::new(database.clone()),
            database,
        }
    }

    pub async fn prepare(
        &self,
        auth: &AuthContext,
        plaintext: &[u8],
    ) -> Result<PreparedInference, InferenceControlError> {
        let requested_model = requested_model(plaintext)?;
        let account_id =
            AccountId::new(auth.account_id.as_ref()).map_err(InferenceControlError::Input)?;
        let catalog = self.catalog.load(&requested_model).await?;
        enforce_capabilities(plaintext, &catalog)?;

        let (api_key_limit_micro_usd, api_key_controlled, required_provider_id) =
            if let AuthPrincipal::ApiKey { key_id } = &auth.principal {
                let key = auth
                    .api_key
                    .as_ref()
                    .ok_or(InferenceControlError::CredentialChanged)?;
                if key.id != key_id.as_ref()
                    || key.owner_account_id != auth.account_id.as_ref()
                    || key.disabled
                {
                    return Err(InferenceControlError::CredentialChanged);
                }
                let admission = self
                    .admit_api_key(
                        auth,
                        key_id,
                        requested_input_tokens(plaintext)?,
                        requested_output_tokens(plaintext)?,
                        &requested_model,
                        &catalog,
                    )
                    .await?;
                let required_provider_id = if admission.self_route_only {
                    Some(
                        self.resolve_owned_provider(&auth.account_id, &catalog)
                            .await?,
                    )
                } else {
                    None
                };
                (admission.limit_micro_usd, true, required_provider_id)
            } else {
                (None, false, None)
            };

        let billing = self.billing_snapshot(&account_id, &catalog).await?;
        Ok(PreparedInference {
            catalog,
            billing,
            api_key_limit_micro_usd,
            api_key_controlled,
            required_provider_id,
        })
    }

    async fn admit_api_key(
        &self,
        auth: &AuthContext,
        key_id: &str,
        input_tokens: i64,
        output_tokens: i64,
        requested_model: &str,
        catalog: &CatalogSnapshot,
    ) -> Result<ApiKeyAdmission, InferenceControlError> {
        let mut transaction = self.database.begin_owned().await?;
        let row = sqlx::query_as::<_, ApiKeyAdmissionRow>(
            r#"
            WITH authority AS MATERIALIZED (
                SELECT 1
                FROM public.coordinator_ownership
                WHERE singleton = TRUE
                  AND owner_id = $1
                  AND epoch = $2
            ),
            current_key AS MATERIALIZED (
                SELECT
                    rpm_limit,
                    itpm_limit,
                    otpm_limit,
                    limit_micro_usd,
                    self_route_only,
                    (
                        allowed_models IN ('', '[]')
                        OR EXISTS (
                            SELECT 1
                            FROM jsonb_array_elements_text(
                                allowed_models::JSONB
                            ) AS allowed(model)
                            WHERE allowed.model IN ($8, $9, $10)
                        )
                    ) AS model_allowed
                FROM public.api_keys
                WHERE id = $3
                  AND key_hash = $4
                  AND owner_account_id = $5
                  AND active
                  AND (expires_at IS NULL OR expires_at > NOW())
                FOR UPDATE
            ),
            pruned AS (
                DELETE FROM rust_coord.api_key_rate_windows
                WHERE window_started_at
                    < date_trunc('minute', NOW()) - INTERVAL '2 minutes'
            ),
            admitted AS (
                INSERT INTO rust_coord.api_key_rate_windows (
                    credential_hash, window_started_at, request_count,
                    input_tokens, reserved_output_tokens, updated_at
                )
                SELECT
                    $4,
                    date_trunc('minute', NOW()),
                    1,
                    $6,
                    $7,
                    NOW()
                FROM authority
                CROSS JOIN current_key
                WHERE current_key.model_allowed
                  AND (current_key.rpm_limit IS NULL OR current_key.rpm_limit >= 1)
                  AND (current_key.itpm_limit IS NULL OR current_key.itpm_limit >= $6)
                  AND (current_key.otpm_limit IS NULL OR current_key.otpm_limit >= $7)
                ON CONFLICT (credential_hash, window_started_at) DO UPDATE SET
                    request_count =
                        api_key_rate_windows.request_count + EXCLUDED.request_count,
                    input_tokens =
                        api_key_rate_windows.input_tokens + EXCLUDED.input_tokens,
                    reserved_output_tokens =
                        api_key_rate_windows.reserved_output_tokens
                            + EXCLUDED.reserved_output_tokens,
                    updated_at = NOW()
                WHERE (
                        (SELECT rpm_limit FROM current_key) IS NULL
                        OR api_key_rate_windows.request_count
                            + EXCLUDED.request_count
                            <= (SELECT rpm_limit FROM current_key)
                    )
                  AND (
                        (SELECT itpm_limit FROM current_key) IS NULL
                        OR api_key_rate_windows.input_tokens
                            + EXCLUDED.input_tokens
                            <= (SELECT itpm_limit FROM current_key)
                    )
                  AND (
                        (SELECT otpm_limit FROM current_key) IS NULL
                        OR api_key_rate_windows.reserved_output_tokens
                            + EXCLUDED.reserved_output_tokens
                            <= (SELECT otpm_limit FROM current_key)
                    )
                RETURNING 1
            ),
            touched AS (
                UPDATE public.api_keys
                SET last_used_at = NOW()
                WHERE id = $3 AND EXISTS (SELECT 1 FROM admitted)
            )
            SELECT
                EXISTS (SELECT 1 FROM authority) AS authority_ok,
                EXISTS (SELECT 1 FROM current_key) AS credential_ok,
                COALESCE(
                    (SELECT model_allowed FROM current_key),
                    FALSE
                ) AS model_allowed,
                EXISTS (SELECT 1 FROM admitted) AS admitted,
                (SELECT limit_micro_usd FROM current_key) AS limit_micro_usd,
                COALESCE(
                    (SELECT self_route_only FROM current_key),
                    FALSE
                ) AS self_route_only
            "#,
        )
        .bind(
            self.database
                .authority()
                .ok_or(InferenceControlError::OwnershipUnavailable)?
                .0
                .owner_id(),
        )
        .bind(
            self.database
                .authority()
                .ok_or(InferenceControlError::OwnershipUnavailable)?
                .0
                .epoch(),
        )
        .bind(key_id)
        .bind(auth.credential_hash.as_ref())
        .bind(auth.account_id.as_ref())
        .bind(input_tokens)
        .bind(output_tokens)
        .bind(requested_model)
        .bind(catalog.public_model.as_ref())
        .bind(catalog.concrete_model.as_str())
        .fetch_one(transaction.connection())
        .await?;
        if !row.authority_ok {
            return Err(InferenceControlError::OwnershipUnavailable);
        }
        if !row.credential_ok {
            return Err(InferenceControlError::CredentialChanged);
        }
        if !row.model_allowed {
            transaction.rollback().await?;
            return Err(InferenceControlError::ModelForbidden);
        }
        if !row.admitted {
            transaction.rollback().await?;
            return Err(InferenceControlError::RateLimited);
        }
        transaction.commit().await?;
        Ok(ApiKeyAdmission {
            limit_micro_usd: row.limit_micro_usd,
            self_route_only: row.self_route_only,
        })
    }

    async fn resolve_owned_provider(
        &self,
        account_id: &str,
        catalog: &CatalogSnapshot,
    ) -> Result<ProviderId, InferenceControlError> {
        let provider_id = sqlx::query_scalar::<_, String>(
            r#"
            SELECT id
            FROM public.providers
            WHERE account_id = $1
              AND connected
              AND trust_level = 'hardware'
              AND (
                    models @> jsonb_build_array(jsonb_build_object(
                        'id', $2::TEXT
                    ))
                    OR models @> jsonb_build_array(jsonb_build_object(
                        'id', $3::TEXT
                    ))
              )
            ORDER BY last_seen DESC, id
            LIMIT 1
            "#,
        )
        .bind(account_id)
        .bind(catalog.concrete_model.as_str())
        .bind(catalog.public_model.as_ref())
        .fetch_optional(self.database.pool())
        .await?
        .ok_or(InferenceControlError::OwnedProviderUnavailable)?;
        let provider_id =
            Uuid::parse_str(&provider_id).map_err(|_| InferenceControlError::CorruptProvider)?;
        ProviderId::new(provider_id).map_err(|_| InferenceControlError::CorruptProvider)
    }

    async fn billing_snapshot(
        &self,
        account_id: &AccountId,
        catalog: &CatalogSnapshot,
    ) -> Result<PilotBilling, InferenceControlError> {
        let settings = sqlx::query_as::<_, BillingSettingsRow>(
            r#"
            SELECT
                settings.platform_account_id,
                settings.base_reservation_micro_usd,
                settings.provider_share_ppm,
                settings.referral_share_ppm,
                settings.rounding_version,
                users.role AS consumer_role,
                users.platform_fee_percent,
                referrer.account_id AS referral_account_id
            FROM public.billing_runtime_settings AS settings
            LEFT JOIN public.users AS users
              ON users.account_id = $1
            LEFT JOIN public.referrals AS referral
              ON referral.referred_account = $1
            LEFT JOIN public.referrers AS referrer
              ON referrer.code = referral.referrer_code
            WHERE settings.singleton
            "#,
        )
        .bind(account_id.as_str())
        .fetch_one(self.database.pool())
        .await?;

        let rows = sqlx::query_as::<_, ProviderBeneficiaryRow>(
            r#"
            SELECT
                providers.id,
                providers.account_id,
                prices.input_price,
                prices.output_price,
                prices.revision AS pricing_version
            FROM public.providers AS providers
            LEFT JOIN public.model_prices AS prices
              ON prices.account_id = providers.account_id
             AND prices.model = $2
             AND prices.input_price > 0
             AND prices.output_price > 0
            WHERE providers.connected AND providers.account_id <> ''
            ORDER BY providers.id
            LIMIT $1
            "#,
        )
        .bind(MAX_PROVIDER_BENEFICIARIES + 1)
        .bind(catalog.concrete_model.as_str())
        .fetch_all(self.database.pool())
        .await?;
        if i64::try_from(rows.len()).unwrap_or(i64::MAX) > MAX_PROVIDER_BENEFICIARIES {
            return Err(InferenceControlError::ProviderBoundExceeded);
        }
        let mut providers = Vec::with_capacity(rows.len());
        for row in rows {
            let provider_id =
                Uuid::parse_str(&row.id).map_err(|_| InferenceControlError::CorruptProvider)?;
            let price_override = provider_price_override(&row)?;
            providers.push(ProviderBeneficiaryEntry {
                provider_id: darkbloom_coordinator_protocol::v2::ProviderId::new(
                    *provider_id.as_bytes(),
                ),
                account_id: AccountId::new(row.account_id).map_err(InferenceControlError::Input)?,
                price_override,
            });
        }

        let is_service_consumer = settings.consumer_role == "service";
        let referral_account_id = if is_service_consumer {
            None
        } else {
            settings
                .referral_account_id
                .map(AccountId::new)
                .transpose()
                .map_err(InferenceControlError::Input)?
        };
        let referral_share_ppm = if referral_account_id.is_some() {
            u32::try_from(settings.referral_share_ppm)
                .map_err(|_| InferenceControlError::CorruptBilling)?
        } else {
            0
        };
        let provider_share_ppm = if is_service_consumer {
            1_000_000
        } else if let Some(platform_fee_percent) = settings.platform_fee_percent {
            let platform_fee_ppm = platform_fee_percent
                .checked_mul(10_000)
                .filter(|value| (0..=1_000_000).contains(value))
                .ok_or(InferenceControlError::CorruptBilling)?;
            u32::try_from(1_000_000 - platform_fee_ppm)
                .map_err(|_| InferenceControlError::CorruptBilling)?
        } else {
            u32::try_from(settings.provider_share_ppm)
                .map_err(|_| InferenceControlError::CorruptBilling)?
        };
        let billing = PilotBilling::new(
            PaidBillingPolicy {
                platform_account_id: AccountId::new(settings.platform_account_id)
                    .map_err(InferenceControlError::Input)?,
                referral_account_id,
                pricing_version: catalog.pricing_version,
                rounding_version: Version::new(
                    u64::try_from(settings.rounding_version)
                        .map_err(|_| InferenceControlError::CorruptBilling)?,
                )
                .map_err(InferenceControlError::Input)?,
                base_reservation: LedgerAmount::from_i64(settings.base_reservation_micro_usd)
                    .map_err(InferenceControlError::Input)?,
                input_micro_usd_per_million: catalog.input_micro_usd_per_million,
                output_micro_usd_per_million: catalog.output_micro_usd_per_million,
                provider_share_ppm,
                referral_share_ppm,
            },
            providers.into(),
        )
        .map_err(|_| InferenceControlError::CorruptBilling)?;
        Ok(if is_service_consumer {
            billing.without_provider_price_overrides()
        } else {
            billing
        })
    }
}

fn requested_model(plaintext: &[u8]) -> Result<String, InferenceControlError> {
    let value: Value =
        serde_json::from_slice(plaintext).map_err(|_| InferenceControlError::InvalidRequest)?;
    value
        .get("model")
        .and_then(Value::as_str)
        .filter(|model| {
            !model.is_empty()
                && model.len() <= 256
                && model.trim() == *model
                && !model.chars().any(char::is_control)
        })
        .map(str::to_owned)
        .ok_or(InferenceControlError::InvalidRequest)
}

fn requested_output_tokens(plaintext: &[u8]) -> Result<i64, InferenceControlError> {
    let value: Value =
        serde_json::from_slice(plaintext).map_err(|_| InferenceControlError::InvalidRequest)?;
    let tokens = value
        .get("max_completion_tokens")
        .or_else(|| value.get("max_tokens"))
        .map_or(Some(1_024), Value::as_u64)
        .filter(|tokens| *tokens > 0)
        .ok_or(InferenceControlError::InvalidRequest)?;
    i64::try_from(tokens).map_err(|_| InferenceControlError::InvalidRequest)
}

fn requested_input_tokens(plaintext: &[u8]) -> Result<i64, InferenceControlError> {
    let value: Value =
        serde_json::from_slice(plaintext).map_err(|_| InferenceControlError::InvalidRequest)?;
    let tokens = value
        .get("messages")
        .map_or_else(|| approximate_tokens(&value), messages_input_tokens);
    i64::try_from(tokens.max(1)).map_err(|_| InferenceControlError::InvalidRequest)
}

fn messages_input_tokens(value: &Value) -> u64 {
    let Some(messages) = value.as_array() else {
        return approximate_tokens(value);
    };
    messages.iter().fold(0_u64, |total, message| {
        total
            .saturating_add(4)
            .saturating_add(message.get("content").map_or(0, content_input_tokens))
    })
}

fn content_input_tokens(value: &Value) -> u64 {
    match value {
        Value::String(text) => text_tokens(text),
        Value::Array(parts) => parts.iter().fold(0_u64, |total, part| {
            let kind = part.get("type").and_then(Value::as_str).unwrap_or_default();
            let tokens = match kind {
                "text" | "input_text" => part
                    .get("text")
                    .and_then(Value::as_str)
                    .map_or(0, text_tokens),
                "image_url" | "input_image" | "image" => 300,
                "video_url" | "input_video" | "video" => 1_500,
                _ => approximate_tokens(part),
            };
            total.saturating_add(tokens)
        }),
        Value::Null => 0,
        _ => approximate_tokens(value),
    }
}

fn approximate_tokens(value: &Value) -> u64 {
    serde_json::to_vec(value)
        .ok()
        .and_then(|bytes| u64::try_from(bytes.len()).ok())
        .map_or(0, |bytes| (bytes / 4).max(1))
}

fn text_tokens(value: &str) -> u64 {
    u64::try_from(value.len()).map_or(u64::MAX, |bytes| (bytes / 4).max(1))
}

fn enforce_capabilities(
    plaintext: &[u8],
    catalog: &CatalogSnapshot,
) -> Result<(), InferenceControlError> {
    let value: Value =
        serde_json::from_slice(plaintext).map_err(|_| InferenceControlError::InvalidRequest)?;
    let supports = |capability: &str| {
        catalog
            .capabilities
            .iter()
            .any(|candidate| candidate == capability)
    };
    let tools = value
        .get("tools")
        .and_then(Value::as_array)
        .is_some_and(|tools| !tools.is_empty());
    let structured = value
        .get("response_format")
        .and_then(|format| format.get("type"))
        .and_then(Value::as_str)
        .is_some_and(|kind| matches!(kind, "json_object" | "json_schema"));
    let multimodal = value
        .get("messages")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|message| message.get("content").and_then(Value::as_array))
        .flatten()
        .any(|part| {
            part.get("type")
                .and_then(Value::as_str)
                .is_some_and(|kind| matches!(kind, "image_url" | "input_image"))
        });
    if (tools && !supports("tools"))
        || (structured && !supports("structured_output"))
        || (multimodal && !supports("multimodal"))
    {
        return Err(InferenceControlError::CapabilityUnavailable);
    }
    Ok(())
}

#[derive(Debug, FromRow)]
struct ApiKeyAdmissionRow {
    authority_ok: bool,
    credential_ok: bool,
    model_allowed: bool,
    admitted: bool,
    limit_micro_usd: Option<i64>,
    self_route_only: bool,
}

#[derive(Clone, Copy, Debug)]
struct ApiKeyAdmission {
    limit_micro_usd: Option<i64>,
    self_route_only: bool,
}

#[derive(Debug, FromRow)]
struct BillingSettingsRow {
    platform_account_id: String,
    base_reservation_micro_usd: i64,
    provider_share_ppm: i32,
    referral_share_ppm: i32,
    rounding_version: i64,
    consumer_role: String,
    platform_fee_percent: Option<i64>,
    referral_account_id: Option<String>,
}

#[derive(Debug, FromRow)]
struct ProviderBeneficiaryRow {
    id: String,
    account_id: String,
    input_price: Option<i64>,
    output_price: Option<i64>,
    pricing_version: Option<i64>,
}

fn provider_price_override(
    row: &ProviderBeneficiaryRow,
) -> Result<Option<ProviderPriceOverride>, InferenceControlError> {
    match (row.input_price, row.output_price, row.pricing_version) {
        (None, None, None) => Ok(None),
        (Some(input), Some(output), Some(version)) => Ok(Some(ProviderPriceOverride {
            pricing_version: Version::new(
                u64::try_from(version).map_err(|_| InferenceControlError::CorruptBilling)?,
            )
            .map_err(InferenceControlError::Input)?,
            input_micro_usd_per_million: LedgerAmount::from_i64(input)
                .map_err(InferenceControlError::Input)?,
            output_micro_usd_per_million: LedgerAmount::from_i64(output)
                .map_err(InferenceControlError::Input)?,
        })),
        _ => Err(InferenceControlError::CorruptBilling),
    }
}

#[derive(Debug, Error)]
pub enum InferenceControlError {
    #[error("request body or model is invalid")]
    InvalidRequest,
    #[error("the authenticated API key changed or was revoked")]
    CredentialChanged,
    #[error("the API key does not allow this model")]
    ModelForbidden,
    #[error("the API key rate limit was exceeded")]
    RateLimited,
    #[error("the active model does not support the requested capability")]
    CapabilityUnavailable,
    #[error("self-route-only key has no matching trusted owned provider")]
    OwnedProviderUnavailable,
    #[error("coordinator ownership is unavailable")]
    OwnershipUnavailable,
    #[error("provider control data is corrupt")]
    CorruptProvider,
    #[error("provider beneficiary bound was exceeded")]
    ProviderBoundExceeded,
    #[error("billing control data is corrupt")]
    CorruptBilling,
    #[error(transparent)]
    Catalog(#[from] CatalogError),
    #[error(transparent)]
    Input(#[from] InputError),
    #[error(transparent)]
    Database(#[from] sqlx::Error),
    #[error(transparent)]
    DurableDatabase(#[from] crate::database::DatabaseError),
}
