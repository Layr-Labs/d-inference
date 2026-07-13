use serde::Serialize;
use sqlx::Row;
use uuid::Uuid;

use super::{
    error::BillingError,
    money::format_usd,
    store::{Balance, BillingStore, ensure_balance_row, validate_balance},
};

#[derive(Clone, Debug)]
pub(super) struct InviteService {
    store: BillingStore,
}

impl InviteService {
    pub(super) fn new(store: BillingStore) -> Self {
        Self { store }
    }

    pub(super) async fn create(
        &self,
        requested_code: &str,
        amount_micro_usd: i64,
        max_uses: i32,
        expires_at: Option<&str>,
    ) -> Result<InviteCodeView, BillingError> {
        if amount_micro_usd <= 0 {
            return Err(BillingError::bad_request(
                "invite credit amount must be positive",
            ));
        }
        if max_uses <= 0 {
            return Err(BillingError::bad_request("max_uses must be positive"));
        }
        let code = if requested_code.trim().is_empty() {
            format!("INV-{}", Uuid::new_v4().simple())
                .chars()
                .take(20)
                .collect()
        } else {
            normalize_invite_code(requested_code)?
        };
        if let Some(expires_at) = expires_at {
            validate_timestamp(expires_at)?;
        }
        let mut transaction = self.store.begin("create invite code").await?;
        let result = sqlx::query(
            r#"
            INSERT INTO public.invite_codes (
                code, amount_micro_usd, max_uses, used_count, active, expires_at
            )
            VALUES ($1, $2, $3, 0, TRUE, $4::TIMESTAMPTZ)
            "#,
        )
        .bind(&code)
        .bind(amount_micro_usd)
        .bind(max_uses)
        .bind(expires_at)
        .execute(transaction.connection())
        .await;
        if let Err(error) = result {
            if is_unique_violation(&error) {
                return Err(BillingError::conflict(
                    "invite_code_exists",
                    "invite code already exists",
                ));
            }
            if is_invalid_timestamp(&error) {
                return Err(BillingError::bad_request(
                    "expires_at must be an RFC 3339 timestamp",
                ));
            }
            return Err(BillingError::internal("create invite code", error));
        }
        transaction
            .commit()
            .await
            .map_err(|error| BillingError::external_unknown(error.to_string()))?;
        Ok(InviteCodeView {
            code,
            amount_micro_usd,
            amount_usd: format_usd(amount_micro_usd),
            max_uses,
            used_count: 0,
            active: true,
            expires_at: expires_at.map(str::to_owned),
            created_at: None,
        })
    }

    pub(super) async fn list(&self) -> Result<Vec<InviteCodeView>, BillingError> {
        let rows = sqlx::query(
            r#"
            SELECT
                code, amount_micro_usd, max_uses, used_count, active,
                CASE WHEN expires_at IS NULL THEN NULL
                     ELSE (expires_at AT TIME ZONE 'UTC')::TEXT || 'Z'
                END AS expires_at,
                (created_at AT TIME ZONE 'UTC')::TEXT || 'Z' AS created_at
            FROM public.invite_codes
            ORDER BY created_at DESC
            "#,
        )
        .fetch_all(self.store.pool())
        .await
        .map_err(|error| BillingError::internal("list invite codes", error))?;
        Ok(rows
            .into_iter()
            .map(|row| {
                let amount = row.get::<i64, _>("amount_micro_usd");
                InviteCodeView {
                    code: row.get("code"),
                    amount_micro_usd: amount,
                    amount_usd: format_usd(amount),
                    max_uses: row.get("max_uses"),
                    used_count: row.get("used_count"),
                    active: row.get("active"),
                    expires_at: row.get("expires_at"),
                    created_at: row.get("created_at"),
                }
            })
            .collect())
    }

    pub(super) async fn deactivate(&self, supplied_code: &str) -> Result<(), BillingError> {
        let code = normalize_invite_code(supplied_code)?;
        let mut transaction = self.store.begin("deactivate invite code").await?;
        let result = sqlx::query(
            "UPDATE public.invite_codes SET active = FALSE WHERE code = $1 RETURNING code",
        )
        .bind(&code)
        .fetch_optional(transaction.connection())
        .await
        .map_err(|error| BillingError::internal("deactivate invite code", error))?;
        if result.is_none() {
            return Err(BillingError::not_found("invite code was not found"));
        }
        transaction
            .commit()
            .await
            .map_err(|error| BillingError::external_unknown(error.to_string()))?;
        Ok(())
    }

    pub(super) async fn redeem(
        &self,
        supplied_code: &str,
        account_id: &str,
    ) -> Result<InviteRedemptionView, BillingError> {
        let code = normalize_invite_code(supplied_code)?;
        let mut transaction = self.store.begin("redeem invite code").await?;
        let invite = sqlx::query(
            r#"
            SELECT
                amount_micro_usd, max_uses, used_count, active,
                expires_at IS NOT NULL AND expires_at <= NOW() AS expired
            FROM public.invite_codes
            WHERE code = $1
            FOR UPDATE
            "#,
        )
        .bind(&code)
        .fetch_optional(transaction.connection())
        .await
        .map_err(|error| BillingError::internal("lock invite code", error))?
        .ok_or_else(|| BillingError::not_found("invite code was not found"))?;
        if !invite.get::<bool, _>("active") {
            return Err(BillingError::bad_request("invite code is inactive"));
        }
        if invite.get::<bool, _>("expired") {
            return Err(BillingError::bad_request("invite code has expired"));
        }
        let max_uses = invite.get::<i32, _>("max_uses");
        let used_count = invite.get::<i32, _>("used_count");
        if max_uses <= 0 || used_count < 0 {
            return Err(BillingError::internal(
                "redeem invite code",
                "invalid persisted invite counters",
            ));
        }
        if used_count >= max_uses {
            return Err(BillingError::bad_request(
                "invite code has reached its maximum uses",
            ));
        }
        let amount = invite.get::<i64, _>("amount_micro_usd");
        if amount <= 0 {
            return Err(BillingError::internal(
                "redeem invite code",
                "invalid persisted invite amount",
            ));
        }
        let inserted = sqlx::query(
            r#"
            INSERT INTO public.invite_redemptions (code, account_id)
            VALUES ($1, $2)
            ON CONFLICT (code, account_id) DO NOTHING
            RETURNING code
            "#,
        )
        .bind(&code)
        .bind(account_id)
        .fetch_optional(transaction.connection())
        .await
        .map_err(|error| BillingError::internal("record invite redemption", error))?;
        if inserted.is_none() {
            return Err(BillingError::conflict(
                "invite_already_redeemed",
                "account already redeemed this invite code",
            ));
        }
        sqlx::query(
            r#"
            UPDATE public.invite_codes
            SET used_count = used_count + 1
            WHERE code = $1 AND used_count = $2 AND used_count < max_uses
            "#,
        )
        .bind(&code)
        .bind(used_count)
        .execute(transaction.connection())
        .await
        .map_err(|error| BillingError::internal("increment invite use", error))?;
        ensure_balance_row(transaction.connection(), account_id).await?;
        let balance = sqlx::query(
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
        .map_err(|error| BillingError::internal("lock invite balance", error))?;
        let total = balance.get::<i64, _>("balance_micro_usd");
        let withdrawable = balance.get::<i64, _>("withdrawable_micro_usd");
        validate_balance(total, withdrawable)?;
        let next_total = total.checked_add(amount).ok_or_else(|| {
            BillingError::bad_request("invite credit would overflow account balance")
        })?;
        sqlx::query(
            r#"
            UPDATE public.balances
            SET balance_micro_usd = $2, updated_at = NOW()
            WHERE account_id = $1
            "#,
        )
        .bind(account_id)
        .bind(next_total)
        .execute(transaction.connection())
        .await
        .map_err(|error| BillingError::internal("credit invite balance", error))?;
        sqlx::query(
            r#"
            INSERT INTO public.ledger_entries (
                account_id, entry_type, amount_micro_usd, balance_after, reference
            )
            VALUES ($1, 'invite_credit', $2, $3, $4)
            "#,
        )
        .bind(account_id)
        .bind(amount)
        .bind(next_total)
        .bind(format!("invite:{code}"))
        .execute(transaction.connection())
        .await
        .map_err(|error| BillingError::internal("record invite credit", error))?;
        transaction
            .commit()
            .await
            .map_err(|error| BillingError::external_unknown(error.to_string()))?;
        Ok(InviteRedemptionView {
            code,
            credited_micro_usd: amount,
            credited_usd: format_usd(amount),
            balance: Balance {
                balance_micro_usd: next_total,
                balance_usd: format_usd(next_total),
                withdrawable_micro_usd: withdrawable,
                withdrawable_usd: format_usd(withdrawable),
            },
        })
    }
}

fn normalize_invite_code(code: &str) -> Result<String, BillingError> {
    let code = code.trim().to_ascii_uppercase();
    if code.is_empty()
        || code.len() > 64
        || !code
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err(BillingError::bad_request(
            "invite code must be 1-64 ASCII letters, numbers, hyphens, or underscores",
        ));
    }
    Ok(code)
}

fn validate_timestamp(value: &str) -> Result<(), BillingError> {
    if value.len() < 20
        || value.len() > 40
        || !value.contains('T')
        || value.chars().any(char::is_control)
    {
        return Err(BillingError::bad_request(
            "expires_at must be an RFC 3339 timestamp",
        ));
    }
    Ok(())
}

fn is_unique_violation(error: &sqlx::Error) -> bool {
    error
        .as_database_error()
        .and_then(|error| error.code())
        .is_some_and(|code| code == "23505")
}

fn is_invalid_timestamp(error: &sqlx::Error) -> bool {
    error
        .as_database_error()
        .and_then(|error| error.code())
        .is_some_and(|code| code == "22007")
}

#[derive(Debug, Serialize)]
pub(super) struct InviteCodeView {
    pub code: String,
    pub amount_micro_usd: i64,
    pub amount_usd: String,
    pub max_uses: i32,
    pub used_count: i32,
    pub active: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub created_at: Option<String>,
}

#[derive(Debug, Serialize)]
pub(super) struct InviteRedemptionView {
    pub code: String,
    pub credited_micro_usd: i64,
    pub credited_usd: String,
    #[serde(flatten)]
    pub balance: Balance,
}
