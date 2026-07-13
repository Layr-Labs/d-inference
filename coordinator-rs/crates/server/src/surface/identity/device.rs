use std::{sync::Arc, time::Duration};

use rand::TryRng as _;
use sqlx::FromRow;
use subtle::ConstantTimeEq as _;

use super::{
    api_keys::hash_secret,
    error::IdentityError,
    store::IdentityStore,
    types::{
        DeviceApprovedResponse, DeviceCodeResponse, DeviceTokenResponse, IdentitySurfaceConfig,
    },
};

pub const DEVICE_CODE_EXPIRY: Duration = Duration::from_secs(15 * 60);
pub const DEVICE_CODE_POLL_INTERVAL: Duration = Duration::from_secs(5);
pub(super) const MAX_ACTIVE_DEVICE_CODES: i64 = 10_000;
const DEVICE_CODE_CAP_LOCK: i64 = 1_823_760_041;

#[derive(Clone, Debug)]
pub struct DeviceService {
    store: IdentityStore,
    config: Arc<IdentitySurfaceConfig>,
}

impl DeviceService {
    pub fn new(store: IdentityStore, config: Arc<IdentitySurfaceConfig>) -> Self {
        Self { store, config }
    }

    pub async fn create_code(&self) -> Result<DeviceCodeResponse, IdentityError> {
        for _ in 0..4 {
            let device_code = generate_hex_secret(32)?;
            let user_code = generate_user_code()?;
            let (authority_ok, capacity_available, inserted): (bool, bool, bool) = self
                .store
                .bounded(
                    sqlx::query_as(
                        r#"
                        WITH authority AS MATERIALIZED (
                            SELECT EXISTS (
                                SELECT 1 FROM public.coordinator_ownership
                                WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                                FOR SHARE
                            ) AS ok
                        ), serialized AS MATERIALIZED (
                            SELECT pg_advisory_xact_lock($6::BIGINT)
                            FROM authority
                            WHERE ok
                        ), pruned AS (
                            DELETE FROM public.device_codes
                            WHERE expires_at <= NOW()
                              AND EXISTS (SELECT 1 FROM serialized)
                        ), capacity AS MATERIALIZED (
                            SELECT COUNT(*) < $7::BIGINT AS available
                            FROM public.device_codes
                            CROSS JOIN serialized
                            WHERE expires_at > NOW()
                              AND status IN ('pending', 'approved')
                        ), inserted AS (
                            INSERT INTO public.device_codes (
                                device_code, user_code, account_id, status, expires_at
                            )
                            SELECT
                                $3, $4, '', 'pending',
                                NOW() + ($5::BIGINT * INTERVAL '1 second')
                            FROM authority
                            CROSS JOIN capacity
                            WHERE ok AND capacity.available
                            RETURNING 1
                        )
                        SELECT
                            authority.ok,
                            COALESCE(capacity.available, FALSE),
                            EXISTS (SELECT 1 FROM inserted)
                        FROM authority
                        LEFT JOIN capacity ON TRUE
                        "#,
                    )
                    .bind(self.store.owner_id())
                    .bind(self.store.epoch())
                    .bind(&device_code)
                    .bind(&user_code)
                    .bind(duration_seconds_i64(DEVICE_CODE_EXPIRY))
                    .bind(DEVICE_CODE_CAP_LOCK)
                    .bind(MAX_ACTIVE_DEVICE_CODES)
                    .fetch_one(self.store.pool()),
                )
                .await
                .or_else(|error| {
                    if is_unique_violation(&error) {
                        Ok((true, true, false))
                    } else {
                        Err(error)
                    }
                })?;
            if !authority_ok {
                return Err(IdentityError::OwnershipUnavailable);
            }
            if !capacity_available {
                return Err(IdentityError::RateLimited(DEVICE_CODE_POLL_INTERVAL));
            }
            if !inserted {
                continue;
            }
            return Ok(DeviceCodeResponse {
                device_code,
                user_code,
                verification_uri: format!("{}/link", self.config.console_url.trim_end_matches('/')),
                expires_in: DEVICE_CODE_EXPIRY.as_secs(),
                interval: DEVICE_CODE_POLL_INTERVAL.as_secs(),
            });
        }
        Err(IdentityError::Unavailable)
    }

    pub async fn approve(
        &self,
        account_id: &str,
        user_code: &str,
    ) -> Result<DeviceApprovedResponse, IdentityError> {
        let user_code = normalize_user_code(user_code)?;
        let row = self
            .store
            .bounded(
                sqlx::query_as::<_, ApprovalRow>(
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT EXISTS (
                            SELECT 1 FROM public.coordinator_ownership
                            WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                            FOR SHARE
                        ) AS ok
                    ), located AS MATERIALIZED (
                        SELECT device_code, status, expires_at
                        FROM public.device_codes
                        WHERE user_code = $3
                        FOR UPDATE
                    ), approved AS (
                        UPDATE public.device_codes AS codes
                        SET status = 'approved', account_id = $4
                        FROM authority, located
                        WHERE codes.device_code = located.device_code
                          AND codes.expires_at > NOW()
                          AND (
                              codes.status = 'pending'
                              OR (
                                  codes.status = 'approved'
                                  AND codes.account_id = $4
                              )
                          )
                          AND authority.ok
                        RETURNING codes.device_code
                    )
                    SELECT
                        authority.ok AS authority_ok,
                        located.device_code IS NOT NULL AS found,
                        COALESCE(located.expires_at <= NOW(), FALSE) AS expired,
                        COALESCE(located.status, '') AS status,
                        approved.device_code IS NOT NULL AS approved
                    FROM authority
                    LEFT JOIN located ON TRUE
                    LEFT JOIN approved ON TRUE
                    "#,
                )
                .bind(self.store.owner_id())
                .bind(self.store.epoch())
                .bind(&user_code)
                .bind(account_id)
                .fetch_one(self.store.pool()),
            )
            .await?;
        if !row.authority_ok {
            return Err(IdentityError::OwnershipUnavailable);
        }
        if !row.found {
            return Err(IdentityError::not_found(
                "device code not found; check the code and try again",
            ));
        }
        if row.expired {
            return Err(IdentityError::expired(
                "this code has expired; start device login again",
            ));
        }
        if !row.approved {
            return Err(IdentityError::conflict(if row.status == "pending" {
                "device code was approved by another account"
            } else {
                "this code has already been used"
            }));
        }
        Ok(DeviceApprovedResponse {
            status: "approved",
            message: "Device linked successfully. Your provider will connect shortly.",
        })
    }

    pub async fn poll(&self, device_code: &str) -> Result<DeviceTokenResponse, IdentityError> {
        validate_device_secret(device_code)?;
        let raw_token = format!("eigeninference-pt-{}", generate_hex_secret(32)?);
        let token_hash = hash_secret(&raw_token);
        let row = self
            .store
            .bounded(
                sqlx::query_as::<_, PollRow>(
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT EXISTS (
                            SELECT 1 FROM public.coordinator_ownership
                            WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                            FOR SHARE
                        ) AS ok
                    ), located AS MATERIALIZED (
                        SELECT device_code, user_code, account_id, status, expires_at
                        FROM public.device_codes
                        WHERE device_code = $3
                        FOR UPDATE
                    ), consumed AS (
                        UPDATE public.device_codes AS codes
                        SET status = 'consumed'
                        FROM authority, located
                        WHERE codes.device_code = located.device_code
                          AND located.status = 'approved'
                          AND located.expires_at > NOW()
                          AND located.account_id <> ''
                          AND authority.ok
                        RETURNING
                            codes.device_code, codes.user_code, codes.account_id
                    ), issued AS (
                        INSERT INTO public.provider_tokens (
                            token_hash, account_id, label, active
                        )
                        SELECT
                            $4, consumed.account_id,
                            'device-' || consumed.user_code, TRUE
                        FROM consumed
                        RETURNING account_id
                    )
                    SELECT
                        authority.ok AS authority_ok,
                        located.device_code,
                        COALESCE(located.status, '') AS status,
                        COALESCE(located.expires_at <= NOW(), FALSE) AS expired,
                        issued.account_id AS issued_account_id
                    FROM authority
                    LEFT JOIN located ON TRUE
                    LEFT JOIN issued ON TRUE
                    "#,
                )
                .bind(self.store.owner_id())
                .bind(self.store.epoch())
                .bind(device_code)
                .bind(&token_hash)
                .fetch_one(self.store.pool()),
            )
            .await?;
        if !row.authority_ok {
            return Err(IdentityError::OwnershipUnavailable);
        }
        if !constant_time_device_match(device_code, row.device_code.as_deref()) {
            return Err(IdentityError::not_found("device code not found"));
        }
        if row.expired {
            return Err(IdentityError::expired("device code has expired"));
        }
        if row.status == "pending" {
            return Ok(DeviceTokenResponse::Pending);
        }
        if let Some(account_id) = row.issued_account_id {
            return Ok(DeviceTokenResponse::Authorized {
                token: raw_token,
                account_id,
            });
        }
        Err(IdentityError::expired(
            "device code has already been consumed",
        ))
    }
}

#[derive(FromRow)]
struct ApprovalRow {
    authority_ok: bool,
    found: bool,
    expired: bool,
    status: String,
    approved: bool,
}

#[derive(FromRow)]
struct PollRow {
    authority_ok: bool,
    device_code: Option<String>,
    status: String,
    expired: bool,
    issued_account_id: Option<String>,
}

fn normalize_user_code(value: &str) -> Result<String, IdentityError> {
    let normalized = value.trim().to_ascii_uppercase();
    if normalized.len() != 9
        || normalized.as_bytes().get(4) != Some(&b'-')
        || normalized.bytes().enumerate().any(|(index, byte)| {
            index != 4
                && !matches!(
                    byte,
                    b'A'..=b'Z' | b'2'..=b'9'
                )
        })
    {
        return Err(IdentityError::invalid(
            "user_code must use the XXXX-XXXX format",
        ));
    }
    Ok(normalized)
}

fn validate_device_secret(value: &str) -> Result<(), IdentityError> {
    if value.len() != 64 || value.bytes().any(|byte| !byte.is_ascii_hexdigit()) {
        return Err(IdentityError::not_found("device code not found"));
    }
    Ok(())
}

fn constant_time_device_match(expected: &str, stored: Option<&str>) -> bool {
    let missing_hash = "0000000000000000000000000000000000000000000000000000000000000000";
    let equal = expected
        .as_bytes()
        .ct_eq(stored.unwrap_or(missing_hash).as_bytes())
        .unwrap_u8()
        == 1;
    equal && stored.is_some()
}

fn generate_hex_secret(bytes: usize) -> Result<String, IdentityError> {
    let mut random = vec![0_u8; bytes];
    rand::rngs::SysRng
        .try_fill_bytes(&mut random)
        .map_err(|_| IdentityError::Unavailable)?;
    let mut encoded = String::with_capacity(bytes * 2);
    for byte in random {
        use std::fmt::Write as _;
        let _ = write!(encoded, "{byte:02x}");
    }
    Ok(encoded)
}

fn generate_user_code() -> Result<String, IdentityError> {
    const ALPHABET: &[u8] = b"ABCDEFGHJKMNPQRSTUVWXYZ23456789";
    let ceiling = u8::MAX - (u8::MAX % u8::try_from(ALPHABET.len()).unwrap_or(u8::MAX));
    let mut output = String::with_capacity(9);
    while output.len() < 8 {
        let mut byte = [0_u8; 1];
        rand::rngs::SysRng
            .try_fill_bytes(&mut byte)
            .map_err(|_| IdentityError::Unavailable)?;
        if byte[0] >= ceiling {
            continue;
        }
        output.push(char::from(ALPHABET[usize::from(byte[0]) % ALPHABET.len()]));
    }
    output.insert(4, '-');
    Ok(output)
}

fn duration_seconds_i64(duration: Duration) -> i64 {
    i64::try_from(duration.as_secs()).unwrap_or(i64::MAX)
}

fn is_unique_violation(error: &IdentityError) -> bool {
    matches!(
        error,
        IdentityError::Database(error)
            if error
                .as_database_error()
                .and_then(|error| error.code())
                .is_some_and(|code| code == "23505")
    )
}
