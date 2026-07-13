use serde::Serialize;
use sqlx::Row;

use super::{
    error::BillingError,
    money::format_usd,
    store::{Balance, BillingStore},
};

#[derive(Clone, Debug)]
pub struct ReferralService {
    store: BillingStore,
}

impl ReferralService {
    pub(super) fn new(store: BillingStore) -> Self {
        Self { store }
    }

    pub async fn share_percent(&self) -> Result<u32, BillingError> {
        let share_ppm = self.share_ppm().await?;
        u32::try_from(share_ppm / 10_000)
            .map_err(|_| BillingError::internal("read referral policy", "invalid referral share"))
    }

    /// Resolves and freezes a referral split without moving funds. The caller
    /// passes the gross platform fee; the returned platform amount plus reward
    /// always equals that fee exactly.
    pub async fn allocation(
        &self,
        referred_account: &str,
        gross_platform_fee_micro_usd: i64,
    ) -> Result<ReferralAllocation, BillingError> {
        if gross_platform_fee_micro_usd < 0 {
            return Err(BillingError::bad_request(
                "gross platform fee must not be negative",
            ));
        }
        let row = sqlx::query(
            r#"
            SELECT
                referrers.account_id,
                settings.referral_share_ppm
            FROM public.billing_runtime_settings AS settings
            LEFT JOIN public.referrals
              ON referrals.referred_account = $1
            LEFT JOIN public.referrers
              ON referrers.code = referrals.referrer_code
            WHERE settings.singleton
            "#,
        )
        .bind(referred_account)
        .fetch_one(self.store.pool())
        .await
        .map_err(|error| BillingError::internal("resolve referral allocation", error))?;
        let beneficiary = row.get::<Option<String>, _>("account_id");
        let share_ppm = row.get::<i32, _>("referral_share_ppm");
        let share_ppm = u32::try_from(share_ppm)
            .ok()
            .filter(|share| *share <= 1_000_000)
            .ok_or_else(|| {
                BillingError::internal("resolve referral allocation", "invalid referral share")
            })?;
        let share_percent = share_ppm / 10_000;
        let Some(beneficiary_account_id) = beneficiary else {
            return Ok(ReferralAllocation {
                beneficiary_account_id: None,
                reward_micro_usd: 0,
                platform_fee_micro_usd: gross_platform_fee_micro_usd,
                share_percent,
            });
        };
        let reward = i128::from(gross_platform_fee_micro_usd)
            .checked_mul(i128::from(share_ppm))
            .ok_or_else(|| BillingError::bad_request("referral allocation overflow"))?
            / 1_000_000;
        let reward = i64::try_from(reward)
            .map_err(|_| BillingError::bad_request("referral allocation overflow"))?;
        let platform_fee = gross_platform_fee_micro_usd
            .checked_sub(reward)
            .ok_or_else(|| BillingError::bad_request("referral allocation underflow"))?;
        Ok(ReferralAllocation {
            beneficiary_account_id: (reward > 0).then_some(beneficiary_account_id),
            reward_micro_usd: reward,
            platform_fee_micro_usd: platform_fee,
            share_percent,
        })
    }

    pub(super) async fn register(
        &self,
        account_id: &str,
        desired_code: &str,
    ) -> Result<ReferrerView, BillingError> {
        let code = normalize_code(desired_code)?;
        let share_percent = self.share_percent().await?;
        let mut transaction = self.store.begin("register referral code").await?;
        sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1))")
            .bind(format!("referral:{account_id}:{code}"))
            .execute(transaction.connection())
            .await
            .map_err(|error| BillingError::internal("lock referral registration", error))?;
        let existing =
            sqlx::query("SELECT account_id, code FROM public.referrers WHERE account_id = $1")
                .bind(account_id)
                .fetch_optional(transaction.connection())
                .await
                .map_err(|error| BillingError::internal("read referral registration", error))?;
        if let Some(existing) = existing {
            let existing_code = existing.get::<String, _>("code");
            transaction
                .rollback()
                .await
                .map_err(|error| BillingError::internal("finish referral replay", error))?;
            return Ok(ReferrerView {
                code: existing_code,
                share_percent,
            });
        }
        let owner: Option<String> =
            sqlx::query_scalar("SELECT account_id FROM public.referrers WHERE code = $1")
                .bind(&code)
                .fetch_optional(transaction.connection())
                .await
                .map_err(|error| BillingError::internal("check referral code", error))?;
        if owner.is_some() {
            return Err(BillingError::conflict(
                "referral_code_taken",
                "referral code is already taken",
            ));
        }
        sqlx::query("INSERT INTO public.referrers (account_id, code) VALUES ($1, $2)")
            .bind(account_id)
            .bind(&code)
            .execute(transaction.connection())
            .await
            .map_err(|error| {
                if is_unique_violation(&error) {
                    BillingError::conflict("referral_code_taken", "referral code is already taken")
                } else {
                    BillingError::internal("create referral code", error)
                }
            })?;
        transaction
            .commit()
            .await
            .map_err(|error| BillingError::external_unknown(error.to_string()))?;
        Ok(ReferrerView {
            code,
            share_percent,
        })
    }

    pub(super) async fn apply(
        &self,
        referred_account: &str,
        supplied_code: &str,
    ) -> Result<String, BillingError> {
        let code = normalize_code(supplied_code)?;
        let mut transaction = self.store.begin("apply referral code").await?;
        sqlx::query("SELECT pg_advisory_xact_lock(hashtext($1))")
            .bind(format!("referral-apply:{referred_account}"))
            .execute(transaction.connection())
            .await
            .map_err(|error| BillingError::internal("lock referral application", error))?;
        let referrer: Option<String> =
            sqlx::query_scalar("SELECT account_id FROM public.referrers WHERE code = $1")
                .bind(&code)
                .fetch_optional(transaction.connection())
                .await
                .map_err(|error| BillingError::internal("read referral code", error))?;
        let Some(referrer) = referrer else {
            return Err(BillingError::bad_request("invalid referral code"));
        };
        if referrer == referred_account {
            return Err(BillingError::bad_request("an account cannot refer itself"));
        }
        let existing: Option<String> = sqlx::query_scalar(
            "SELECT referrer_code FROM public.referrals WHERE referred_account = $1",
        )
        .bind(referred_account)
        .fetch_optional(transaction.connection())
        .await
        .map_err(|error| BillingError::internal("read existing referral", error))?;
        if let Some(existing) = existing {
            if existing == code {
                transaction
                    .rollback()
                    .await
                    .map_err(|error| BillingError::internal("finish referral replay", error))?;
                return Ok(code);
            }
            return Err(BillingError::conflict(
                "referral_already_applied",
                "account already has a different referrer",
            ));
        }
        sqlx::query(
            "INSERT INTO public.referrals (referred_account, referrer_code) VALUES ($1, $2)",
        )
        .bind(referred_account)
        .bind(&code)
        .execute(transaction.connection())
        .await
        .map_err(|error| {
            if is_unique_violation(&error) {
                BillingError::conflict("referral_already_applied", "account already has a referrer")
            } else {
                BillingError::internal("apply referral", error)
            }
        })?;
        transaction
            .commit()
            .await
            .map_err(|error| BillingError::external_unknown(error.to_string()))?;
        Ok(code)
    }

    pub(super) async fn stats(&self, account_id: &str) -> Result<ReferralStats, BillingError> {
        let share_percent = self.share_percent().await?;
        let row = sqlx::query(
            r#"
            SELECT
                referrers.code,
                COUNT(referrals.referred_account)::BIGINT AS total_referred,
                COALESCE((
                    SELECT SUM(entries.amount_micro_usd)
                    FROM public.ledger_entries AS entries
                    WHERE entries.account_id = referrers.account_id
                      AND entries.entry_type = 'referral_reward'
                ), 0)::BIGINT AS total_rewards
            FROM public.referrers
            LEFT JOIN public.referrals
              ON referrals.referrer_code = referrers.code
            WHERE referrers.account_id = $1
            GROUP BY referrers.account_id, referrers.code
            "#,
        )
        .bind(account_id)
        .fetch_optional(self.store.pool())
        .await
        .map_err(|error| BillingError::internal("read referral stats", error))?
        .ok_or_else(|| BillingError::not_found("account is not a registered referrer"))?;
        let total_rewards = row.get::<i64, _>("total_rewards");
        if total_rewards < 0 {
            return Err(BillingError::internal(
                "read referral stats",
                "negative referral rewards",
            ));
        }
        Ok(ReferralStats {
            code: row.get("code"),
            share_percent,
            total_referred: row.get("total_referred"),
            total_rewards_micro_usd: total_rewards,
            total_rewards_usd: format_usd(total_rewards),
            balance: self.store.balance(account_id).await?,
        })
    }

    pub(super) async fn info(&self, account_id: &str) -> Result<ReferralInfo, BillingError> {
        let share_percent = self.share_percent().await?;
        let code: Option<String> =
            sqlx::query_scalar("SELECT code FROM public.referrers WHERE account_id = $1")
                .bind(account_id)
                .fetch_optional(self.store.pool())
                .await
                .map_err(|error| BillingError::internal("read referral info", error))?;
        let code =
            code.ok_or_else(|| BillingError::not_found("account is not a registered referrer"))?;
        let referred_by: Option<String> = sqlx::query_scalar(
            "SELECT referrer_code FROM public.referrals WHERE referred_account = $1",
        )
        .bind(account_id)
        .fetch_optional(self.store.pool())
        .await
        .map_err(|error| BillingError::internal("read referring code", error))?;
        Ok(ReferralInfo {
            code,
            share_percent,
            referred_by,
        })
    }

    async fn share_ppm(&self) -> Result<i32, BillingError> {
        let share: i32 = sqlx::query_scalar(
            "SELECT referral_share_ppm FROM public.billing_runtime_settings WHERE singleton",
        )
        .fetch_one(self.store.pool())
        .await
        .map_err(|error| BillingError::internal("read referral policy", error))?;
        if !(0..=1_000_000).contains(&share) {
            return Err(BillingError::internal(
                "read referral policy",
                "invalid referral share",
            ));
        }
        Ok(share)
    }
}

fn normalize_code(code: &str) -> Result<String, BillingError> {
    let code = code.trim().to_ascii_uppercase();
    if !(3..=20).contains(&code.len())
        || code.starts_with('-')
        || code.ends_with('-')
        || !code
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    {
        return Err(BillingError::bad_request(
            "referral code must be 3-20 ASCII letters, numbers, or interior hyphens",
        ));
    }
    Ok(code)
}

fn is_unique_violation(error: &sqlx::Error) -> bool {
    error
        .as_database_error()
        .and_then(|error| error.code())
        .is_some_and(|code| code == "23505")
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ReferralAllocation {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub beneficiary_account_id: Option<String>,
    pub reward_micro_usd: i64,
    pub platform_fee_micro_usd: i64,
    pub share_percent: u32,
}

#[derive(Debug, Serialize)]
pub(super) struct ReferrerView {
    pub code: String,
    pub share_percent: u32,
}

#[derive(Debug, Serialize)]
pub(super) struct ReferralStats {
    pub code: String,
    pub share_percent: u32,
    pub total_referred: i64,
    pub total_rewards_micro_usd: i64,
    pub total_rewards_usd: String,
    #[serde(flatten)]
    pub balance: Balance,
}

#[derive(Debug, Serialize)]
pub(super) struct ReferralInfo {
    pub code: String,
    pub share_percent: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub referred_by: Option<String>,
}
