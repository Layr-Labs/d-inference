use serde::Serialize;
use serde_json::{Value, json};
use sqlx::{PgPool, Row};

use crate::{
    database::{Database, OwnedTransaction},
    ledger::LedgerService,
};

use super::{error::BillingError, money::format_usd};

#[derive(Clone, Debug)]
pub(super) struct BillingStore {
    database: Database,
    ledger: LedgerService,
}

impl BillingStore {
    pub(super) fn new(database: Database) -> Self {
        Self {
            ledger: LedgerService::new(database.clone()),
            database,
        }
    }

    pub(super) fn ledger(&self) -> &LedgerService {
        &self.ledger
    }

    pub(super) fn pool(&self) -> &PgPool {
        self.database.pool()
    }

    pub(super) async fn begin(
        &self,
        operation: &'static str,
    ) -> Result<OwnedTransaction<'_>, BillingError> {
        let mut transaction = self
            .database
            .begin_owned()
            .await
            .map_err(|error| BillingError::retryable(operation, error))?;
        let owner_id = transaction.context().owner_id().to_owned();
        let epoch = transaction.context().epoch();
        let authority = sqlx::query_scalar::<_, i32>(
            r#"
            SELECT 1
            FROM public.coordinator_ownership
            WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
            FOR SHARE
            "#,
        )
        .bind(owner_id)
        .bind(epoch)
        .fetch_optional(transaction.connection())
        .await
        .map_err(|error| BillingError::internal(operation, error))?;
        if authority != Some(1) {
            return Err(BillingError::unavailable(
                "coordinator ownership changed before the mutation",
            ));
        }
        Ok(transaction)
    }

    pub(super) async fn balance(&self, account_id: &str) -> Result<Balance, BillingError> {
        let row = sqlx::query(
            r#"
            SELECT
                COALESCE(balance_micro_usd, 0) AS balance_micro_usd,
                COALESCE(withdrawable_micro_usd, 0) AS withdrawable_micro_usd
            FROM public.balances
            WHERE account_id = $1
            "#,
        )
        .bind(account_id)
        .fetch_optional(self.pool())
        .await
        .map_err(|error| BillingError::internal("read balance", error))?;
        let (total, withdrawable) = row.map_or((0, 0), |row| {
            (
                row.get::<i64, _>("balance_micro_usd"),
                row.get::<i64, _>("withdrawable_micro_usd"),
            )
        });
        validate_balance(total, withdrawable)?;
        Ok(Balance::new(total, withdrawable))
    }

    pub(super) async fn usage(
        &self,
        account_id: &str,
        limit: i64,
    ) -> Result<Vec<UsageEntry>, BillingError> {
        let rows = sqlx::query(
            r#"
            SELECT
                CASE WHEN request_id <> '' THEN request_id ELSE provider_id END AS job_id,
                CASE WHEN public_model <> '' THEN public_model ELSE model END AS model,
                prompt_tokens,
                completion_tokens,
                cost_micro_usd,
                (created_at AT TIME ZONE 'UTC')::TEXT || 'Z' AS created_at
            FROM public.usage
            WHERE consumer_key_hash = $1
               OR key_id IN (
                    SELECT id FROM public.api_keys WHERE owner_account_id = $1
               )
            ORDER BY created_at DESC
            LIMIT $2
            "#,
        )
        .bind(account_id)
        .bind(limit)
        .fetch_all(self.pool())
        .await
        .map_err(|error| BillingError::internal("read usage", error))?;
        rows.into_iter()
            .map(|row| {
                let prompt_tokens = row.get::<i32, _>("prompt_tokens");
                let completion_tokens = row.get::<i32, _>("completion_tokens");
                let cost = row.get::<i64, _>("cost_micro_usd");
                if prompt_tokens < 0 || completion_tokens < 0 || cost < 0 {
                    return Err(BillingError::internal(
                        "read usage",
                        "negative persisted usage value",
                    ));
                }
                Ok(UsageEntry {
                    job_id: row.get("job_id"),
                    model: row.get("model"),
                    prompt_tokens,
                    completion_tokens,
                    cost_micro_usd: cost,
                    timestamp: row.get("created_at"),
                })
            })
            .collect()
    }

    pub(super) async fn provider_earnings(
        &self,
        account_id: &str,
        provider_key: &str,
        limit: i64,
    ) -> Result<EarningsResponse, BillingError> {
        let owned: bool = sqlx::query_scalar(
            r#"
            SELECT EXISTS (
                SELECT 1
                FROM public.provider_earnings
                WHERE provider_key = $1 AND account_id = $2
                UNION ALL
                SELECT 1
                FROM public.providers
                WHERE account_id = $2
                  AND ($1 = public_key OR $1 = se_public_key OR $1 = id)
            )
            "#,
        )
        .bind(provider_key)
        .bind(account_id)
        .fetch_one(self.pool())
        .await
        .map_err(|error| BillingError::internal("authorize provider earnings", error))?;
        if !owned {
            return Err(BillingError::forbidden(
                "provider earnings are available only to the owning account",
            ));
        }
        self.earnings(Some(provider_key), account_id, limit).await
    }

    pub(super) async fn account_earnings(
        &self,
        account_id: &str,
        limit: i64,
    ) -> Result<EarningsResponse, BillingError> {
        self.earnings(None, account_id, limit).await
    }

    async fn earnings(
        &self,
        provider_key: Option<&str>,
        account_id: &str,
        limit: i64,
    ) -> Result<EarningsResponse, BillingError> {
        let rows = if let Some(provider_key) = provider_key {
            sqlx::query(
                r#"
                SELECT
                    id, account_id, provider_id, provider_key, job_id, model,
                    amount_micro_usd, prompt_tokens, completion_tokens,
                    (created_at AT TIME ZONE 'UTC')::TEXT || 'Z' AS created_at
                FROM public.provider_earnings
                WHERE provider_key = $1 AND account_id = $2
                ORDER BY created_at DESC
                LIMIT $3
                "#,
            )
            .bind(provider_key)
            .bind(account_id)
            .bind(limit)
            .fetch_all(self.pool())
            .await
        } else {
            sqlx::query(
                r#"
                SELECT
                    id, account_id, provider_id, provider_key, job_id, model,
                    amount_micro_usd, prompt_tokens, completion_tokens,
                    (created_at AT TIME ZONE 'UTC')::TEXT || 'Z' AS created_at
                FROM public.provider_earnings
                WHERE account_id = $1
                ORDER BY created_at DESC
                LIMIT $2
                "#,
            )
            .bind(account_id)
            .bind(limit)
            .fetch_all(self.pool())
            .await
        }
        .map_err(|error| BillingError::internal("read earnings", error))?;
        let mut earnings = Vec::with_capacity(rows.len());
        for row in rows {
            let amount = row.get::<i64, _>("amount_micro_usd");
            let prompt = row.get::<i32, _>("prompt_tokens");
            let completion = row.get::<i32, _>("completion_tokens");
            if amount < 0 || prompt < 0 || completion < 0 {
                return Err(BillingError::internal(
                    "read earnings",
                    "negative persisted earning value",
                ));
            }
            earnings.push(Earning {
                id: row.get("id"),
                account_id: row.get("account_id"),
                provider_id: row.get("provider_id"),
                provider_key: row.get("provider_key"),
                job_id: row.get("job_id"),
                model: row.get("model"),
                amount_micro_usd: amount,
                prompt_tokens: prompt,
                completion_tokens: completion,
                created_at: row.get("created_at"),
            });
        }
        let aggregate = if let Some(provider_key) = provider_key {
            sqlx::query(
                r#"
                SELECT
                    COUNT(*)::BIGINT AS count,
                    COALESCE(SUM(amount_micro_usd), 0)::BIGINT AS total,
                    COALESCE(SUM(prompt_tokens), 0)::BIGINT AS prompt,
                    COALESCE(SUM(completion_tokens), 0)::BIGINT AS completion
                FROM public.provider_earnings
                WHERE provider_key = $1 AND account_id = $2
                "#,
            )
            .bind(provider_key)
            .bind(account_id)
            .fetch_one(self.pool())
            .await
        } else {
            sqlx::query(
                r#"
                SELECT
                    COUNT(*)::BIGINT AS count,
                    COALESCE(SUM(amount_micro_usd), 0)::BIGINT AS total,
                    COALESCE(SUM(prompt_tokens), 0)::BIGINT AS prompt,
                    COALESCE(SUM(completion_tokens), 0)::BIGINT AS completion
                FROM public.provider_earnings
                WHERE account_id = $1
                "#,
            )
            .bind(account_id)
            .fetch_one(self.pool())
            .await
        }
        .map_err(|error| BillingError::internal("summarize earnings", error))?;
        let total = aggregate.get::<i64, _>("total");
        if total < 0 {
            return Err(BillingError::internal(
                "summarize earnings",
                "negative persisted earnings total",
            ));
        }
        Ok(EarningsResponse {
            account_id: account_id.to_owned(),
            provider_key: provider_key.map(str::to_owned),
            earnings,
            total_micro_usd: total,
            total_usd: format_usd(total),
            count: aggregate.get("count"),
            prompt_tokens: aggregate.get("prompt"),
            completion_tokens: aggregate.get("completion"),
            balance: self.balance(account_id).await?,
        })
    }

    pub(super) async fn session(
        &self,
        session_id: &str,
        account_id: &str,
        admin: bool,
    ) -> Result<BillingSession, BillingError> {
        let row = sqlx::query(
            r#"
            SELECT
                id, account_id, payment_method, currency, amount_micro_usd,
                external_id, status,
                (created_at AT TIME ZONE 'UTC')::TEXT || 'Z' AS created_at,
                CASE WHEN completed_at IS NULL THEN NULL
                     ELSE (completed_at AT TIME ZONE 'UTC')::TEXT || 'Z'
                END AS completed_at
            FROM public.billing_sessions
            WHERE id = $1 AND (account_id = $2 OR $3)
            "#,
        )
        .bind(session_id)
        .bind(account_id)
        .bind(admin)
        .fetch_optional(self.pool())
        .await
        .map_err(|error| BillingError::internal("read billing session", error))?
        .ok_or_else(|| BillingError::not_found("billing session not found"))?;
        Ok(BillingSession {
            id: row.get("id"),
            account_id: row.get("account_id"),
            payment_method: row.get("payment_method"),
            currency: row.get("currency"),
            amount_micro_usd: row.get("amount_micro_usd"),
            external_id: row.get("external_id"),
            status: row.get("status"),
            created_at: row.get("created_at"),
            completed_at: row.get("completed_at"),
        })
    }

    pub(super) async fn user(&self, account_id: &str) -> Result<UserRecord, BillingError> {
        let row = sqlx::query(
            r#"
            SELECT
                account_id, email, stripe_account_id, stripe_account_status,
                stripe_account_country, stripe_destination_type,
                stripe_destination_last4, stripe_instant_eligible
            FROM public.users
            WHERE account_id = $1
            "#,
        )
        .bind(account_id)
        .fetch_optional(self.pool())
        .await
        .map_err(|error| BillingError::internal("read billing user", error))?
        .ok_or_else(|| BillingError::not_found("authenticated user was not found"))?;
        Ok(UserRecord {
            account_id: row.get("account_id"),
            email: row.get("email"),
            stripe_account_id: row.get("stripe_account_id"),
            stripe_account_status: row.get("stripe_account_status"),
            stripe_account_country: row.get("stripe_account_country"),
            stripe_destination_type: row.get("stripe_destination_type"),
            stripe_destination_last4: row.get("stripe_destination_last4"),
            stripe_instant_eligible: row.get("stripe_instant_eligible"),
        })
    }

    pub(super) async fn user_by_email(&self, email: &str) -> Result<UserRecord, BillingError> {
        let row = sqlx::query(
            r#"
            SELECT
                account_id, email, stripe_account_id, stripe_account_status,
                stripe_account_country, stripe_destination_type,
                stripe_destination_last4, stripe_instant_eligible
            FROM public.users
            WHERE lower(email) = lower($1)
            "#,
        )
        .bind(email)
        .fetch_optional(self.pool())
        .await
        .map_err(|error| BillingError::internal("find billing user", error))?
        .ok_or_else(|| BillingError::not_found("no user found for that email"))?;
        Ok(UserRecord {
            account_id: row.get("account_id"),
            email: row.get("email"),
            stripe_account_id: row.get("stripe_account_id"),
            stripe_account_status: row.get("stripe_account_status"),
            stripe_account_country: row.get("stripe_account_country"),
            stripe_destination_type: row.get("stripe_destination_type"),
            stripe_destination_last4: row.get("stripe_destination_last4"),
            stripe_instant_eligible: row.get("stripe_instant_eligible"),
        })
    }

    pub(super) async fn credit_once(
        &self,
        account_id: &str,
        amount: i64,
        withdrawable: bool,
        entry_type: &'static str,
        reference: &str,
    ) -> Result<Balance, BillingError> {
        if amount <= 0 {
            return Err(BillingError::bad_request("credit amount must be positive"));
        }
        let mut transaction = self.begin("credit account").await?;
        sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1))")
            .bind(format!("{entry_type}:{reference}"))
            .execute(transaction.connection())
            .await
            .map_err(|error| BillingError::internal("lock credit operation", error))?;
        let existing = sqlx::query(
            r#"
            SELECT account_id, amount_micro_usd
            FROM public.ledger_entries
            WHERE entry_type = $1 AND reference = $2
            ORDER BY id
            LIMIT 1
            "#,
        )
        .bind(entry_type)
        .bind(reference)
        .fetch_optional(transaction.connection())
        .await
        .map_err(|error| BillingError::internal("reconcile credit operation", error))?;
        if let Some(existing) = existing {
            if existing.get::<String, _>("account_id") != account_id
                || existing.get::<i64, _>("amount_micro_usd") != amount
            {
                return Err(BillingError::conflict(
                    "idempotency_conflict",
                    "Idempotency-Key was already used with different credit terms",
                ));
            }
            transaction
                .rollback()
                .await
                .map_err(|error| BillingError::internal("finish credit replay", error))?;
            return self.balance(account_id).await;
        }
        ensure_balance_row(transaction.connection(), account_id).await?;
        let row = sqlx::query(
            r#"
            SELECT balance_micro_usd, withdrawable_micro_usd
            FROM public.balances
            WHERE account_id = $1
            FOR UPDATE
            "#,
        )
        .bind(account_id)
        .fetch_one(transaction.connection())
        .await
        .map_err(|error| BillingError::internal("lock credited balance", error))?;
        let total = row.get::<i64, _>("balance_micro_usd");
        let available = row.get::<i64, _>("withdrawable_micro_usd");
        validate_balance(total, available)?;
        let next_total = total
            .checked_add(amount)
            .ok_or_else(|| BillingError::bad_request("credit would overflow micro-USD balance"))?;
        let next_available = if withdrawable {
            available.checked_add(amount).ok_or_else(|| {
                BillingError::bad_request("credit would overflow withdrawable balance")
            })?
        } else {
            available
        };
        validate_balance(next_total, next_available)?;
        sqlx::query(
            r#"
            UPDATE public.balances
            SET balance_micro_usd = $2,
                withdrawable_micro_usd = $3,
                updated_at = NOW()
            WHERE account_id = $1
            "#,
        )
        .bind(account_id)
        .bind(next_total)
        .bind(next_available)
        .execute(transaction.connection())
        .await
        .map_err(|error| BillingError::internal("apply account credit", error))?;
        sqlx::query(
            r#"
            INSERT INTO public.ledger_entries (
                account_id, entry_type, amount_micro_usd, balance_after, reference
            )
            VALUES ($1, $2, $3, $4, $5)
            "#,
        )
        .bind(account_id)
        .bind(entry_type)
        .bind(amount)
        .bind(next_total)
        .bind(reference)
        .execute(transaction.connection())
        .await
        .map_err(|error| BillingError::internal("record account credit", error))?;
        transaction
            .commit()
            .await
            .map_err(|error| BillingError::external_unknown(error.to_string()))?;
        Ok(Balance::new(next_total, next_available))
    }

    pub(super) async fn withdrawals(
        &self,
        account_id: &str,
        limit: i64,
    ) -> Result<Vec<WithdrawalView>, BillingError> {
        let rows = sqlx::query(
            r#"
            SELECT
                id, account_id, stripe_account_id, transfer_id, payout_id,
                sweep_payout_id, amount_micro_usd, fee_micro_usd,
                net_micro_usd, method, status, failure_reason, refunded,
                fee_refunded,
                (created_at AT TIME ZONE 'UTC')::TEXT || 'Z' AS created_at,
                (updated_at AT TIME ZONE 'UTC')::TEXT || 'Z' AS updated_at
            FROM public.stripe_withdrawals
            WHERE account_id = $1
            ORDER BY created_at DESC
            LIMIT $2
            "#,
        )
        .bind(account_id)
        .bind(limit)
        .fetch_all(self.pool())
        .await
        .map_err(|error| BillingError::internal("list withdrawals", error))?;
        Ok(rows
            .into_iter()
            .map(|row| WithdrawalView {
                id: row.get("id"),
                account_id: row.get("account_id"),
                stripe_account_id: row.get("stripe_account_id"),
                transfer_id: row.get("transfer_id"),
                payout_id: row.get("payout_id"),
                sweep_payout_id: row.get("sweep_payout_id"),
                amount_micro_usd: row.get("amount_micro_usd"),
                fee_micro_usd: row.get("fee_micro_usd"),
                net_micro_usd: row.get("net_micro_usd"),
                method: row.get("method"),
                status: row.get("status"),
                failure_reason: row.get("failure_reason"),
                refunded: row.get("refunded"),
                fee_refunded: row.get("fee_refunded"),
                created_at: row.get("created_at"),
                updated_at: row.get("updated_at"),
            })
            .collect())
    }
}

pub(super) async fn ensure_balance_row(
    connection: &mut sqlx::PgConnection,
    account_id: &str,
) -> Result<(), BillingError> {
    sqlx::query(
        r#"
        INSERT INTO public.balances (
            account_id, balance_micro_usd, withdrawable_micro_usd
        )
        VALUES ($1, 0, 0)
        ON CONFLICT (account_id) DO NOTHING
        "#,
    )
    .bind(account_id)
    .execute(connection)
    .await
    .map_err(|error| BillingError::internal("ensure balance row", error))?;
    Ok(())
}

pub(super) fn validate_balance(total: i64, withdrawable: i64) -> Result<(), BillingError> {
    if total < 0 || withdrawable < 0 || withdrawable > total {
        return Err(BillingError::internal(
            "validate balance",
            "stored balance violates total/withdrawable provenance",
        ));
    }
    Ok(())
}

#[derive(Clone, Debug, Serialize)]
pub struct Balance {
    pub balance_micro_usd: i64,
    pub balance_usd: String,
    pub withdrawable_micro_usd: i64,
    pub withdrawable_usd: String,
}

impl Balance {
    fn new(balance_micro_usd: i64, withdrawable_micro_usd: i64) -> Self {
        Self {
            balance_micro_usd,
            balance_usd: format_usd(balance_micro_usd),
            withdrawable_micro_usd,
            withdrawable_usd: format_usd(withdrawable_micro_usd),
        }
    }
}

#[derive(Debug, Serialize)]
pub struct UsageEntry {
    pub job_id: String,
    pub model: String,
    pub prompt_tokens: i32,
    pub completion_tokens: i32,
    pub cost_micro_usd: i64,
    pub timestamp: String,
}

#[derive(Debug, Serialize)]
pub struct Earning {
    pub id: i64,
    pub account_id: String,
    pub provider_id: String,
    pub provider_key: String,
    pub job_id: String,
    pub model: String,
    pub amount_micro_usd: i64,
    pub prompt_tokens: i32,
    pub completion_tokens: i32,
    pub created_at: String,
}

#[derive(Debug, Serialize)]
pub struct EarningsResponse {
    pub account_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider_key: Option<String>,
    pub earnings: Vec<Earning>,
    pub total_micro_usd: i64,
    pub total_usd: String,
    pub count: i64,
    pub prompt_tokens: i64,
    pub completion_tokens: i64,
    #[serde(flatten)]
    pub balance: Balance,
}

#[derive(Debug, Serialize)]
pub struct BillingSession {
    #[serde(rename = "session_id")]
    pub id: String,
    #[serde(skip_serializing)]
    pub account_id: String,
    pub payment_method: String,
    pub currency: String,
    pub amount_micro_usd: i64,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub external_id: String,
    pub status: String,
    pub created_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
}

#[derive(Clone, Debug)]
pub(super) struct UserRecord {
    pub account_id: String,
    pub email: String,
    pub stripe_account_id: String,
    pub stripe_account_status: String,
    pub stripe_account_country: String,
    pub stripe_destination_type: String,
    pub stripe_destination_last4: String,
    pub stripe_instant_eligible: bool,
}

impl UserRecord {
    pub(super) fn status_json(&self, configured: bool) -> Value {
        json!({
            "configured": configured,
            "has_account": !self.stripe_account_id.is_empty(),
            "stripe_account_id": self.stripe_account_id,
            "status": self.stripe_account_status,
            "stripe_account_country": self.stripe_account_country,
            "destination_type": self.stripe_destination_type,
            "destination_last4": self.stripe_destination_last4,
            "instant_eligible": self.stripe_instant_eligible,
        })
    }
}

#[derive(Debug, Serialize)]
pub struct WithdrawalView {
    pub id: String,
    pub account_id: String,
    pub stripe_account_id: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub transfer_id: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub payout_id: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub sweep_payout_id: String,
    pub amount_micro_usd: i64,
    pub fee_micro_usd: i64,
    pub net_micro_usd: i64,
    pub method: String,
    pub status: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub failure_reason: String,
    pub refunded: bool,
    pub fee_refunded: bool,
    pub created_at: String,
    pub updated_at: String,
}

pub(super) fn bounded_limit(value: Option<&str>, default: i64, maximum: i64) -> i64 {
    value
        .and_then(|value| value.parse::<i64>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(default)
        .min(maximum)
}

pub(super) fn query_parameter(query: Option<&str>, key: &str) -> Option<String> {
    url::form_urlencoded::parse(query.unwrap_or_default().as_bytes())
        .find_map(|(candidate, value)| (candidate == key).then(|| value.into_owned()))
}
