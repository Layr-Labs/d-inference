use super::{
    api_key_support::{
        ApiKeyDbRow, MutationKeyRow, ValidatedKeyInput, constant_time_secret_check,
        ensure_authority, generate_key_id, generate_raw_key, is_invalid_timestamp,
        is_unique_violation, key_label, validate_public_id, validate_raw_secret,
    },
    error::IdentityError,
    store::IdentityStore,
    types::{ApiKeyCreate, ApiKeyRecord},
};

pub use super::api_key_support::{ApiKeyPatch, hash_secret};

#[derive(Clone, Debug)]
pub struct ApiKeyService {
    store: IdentityStore,
}

impl ApiKeyService {
    pub fn new(store: IdentityStore) -> Self {
        Self { store }
    }

    pub async fn create(
        &self,
        account_id: &str,
        options: ApiKeyCreate,
    ) -> Result<(String, ApiKeyRecord), IdentityError> {
        let input = ValidatedKeyInput::try_from(options)?;
        for _ in 0..3 {
            let raw = generate_raw_key()?;
            let id = generate_key_id()?;
            let hash = hash_secret(&raw);
            let label = key_label(&raw);
            let row = self
                .store
                .bounded(
                    sqlx::query_as::<_, MutationKeyRow>(
                        r#"
                        WITH authority AS MATERIALIZED (
                            SELECT EXISTS (
                                SELECT 1
                                FROM public.coordinator_ownership
                                WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                                FOR SHARE
                            ) AS ok
                        ), inserted AS (
                            INSERT INTO public.api_keys (
                                id, key_hash, raw_prefix, owner_account_id, name, active,
                                limit_micro_usd, limit_reset, rpm_limit, itpm_limit, otpm_limit,
                                allowed_models, expires_at, created_at, self_route_only
                            )
                            SELECT
                                $4, $5, $6, $3, $7, TRUE,
                                $8, $9, $10, $11, $12,
                                $13, $14::TIMESTAMPTZ, NOW(), $15
                            FROM authority
                            WHERE ok
                              AND ($14::TEXT IS NULL OR $14::TIMESTAMPTZ > NOW())
                            RETURNING *
                        )
                        SELECT
                            authority.ok AS authority_ok,
                            ($14::TEXT IS NULL OR $14::TIMESTAMPTZ > NOW()) AS expiry_ok,
                            inserted.id,
                            inserted.owner_account_id,
                            inserted.name,
                            inserted.raw_prefix AS label,
                            inserted.key_hash,
                            NOT inserted.active AS disabled,
                            inserted.limit_micro_usd,
                            inserted.limit_reset,
                            0::BIGINT AS usage_micro_usd,
                            inserted.rpm_limit,
                            inserted.itpm_limit,
                            inserted.otpm_limit,
                            inserted.allowed_models,
                            inserted.self_route_only,
                            CASE WHEN inserted.expires_at IS NULL THEN NULL ELSE
                                to_char(inserted.expires_at AT TIME ZONE 'UTC',
                                    'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END AS expires_at,
                            CASE WHEN inserted.created_at IS NULL THEN NULL ELSE
                                to_char(inserted.created_at AT TIME ZONE 'UTC',
                                    'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END AS created_at,
                            CASE WHEN inserted.last_used_at IS NULL THEN NULL ELSE
                                to_char(inserted.last_used_at AT TIME ZONE 'UTC',
                                    'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END AS last_used_at
                        FROM authority
                        LEFT JOIN inserted ON TRUE
                        "#,
                    )
                    .bind(self.store.owner_id())
                    .bind(self.store.epoch())
                    .bind(account_id)
                    .bind(&id)
                    .bind(&hash)
                    .bind(&label)
                    .bind(&input.name)
                    .bind(input.limit_micro_usd)
                    .bind(&input.limit_reset)
                    .bind(input.rpm_limit)
                    .bind(input.itpm_limit)
                    .bind(input.otpm_limit)
                    .bind(&input.allowed_models_json)
                    .bind(input.expires_at.as_deref())
                    .bind(input.self_route_only)
                    .fetch_one(self.store.pool()),
                )
                .await;
            match row {
                Ok(row) => return Ok((raw, row.into_record()?)),
                Err(IdentityError::Database(error)) if is_unique_violation(&error) => continue,
                Err(IdentityError::Database(error)) if is_invalid_timestamp(&error) => {
                    return Err(IdentityError::invalid(
                        "expires_at must be a valid RFC 3339 timestamp",
                    ));
                }
                Err(error) => return Err(error),
            }
        }
        Err(IdentityError::Unavailable)
    }

    pub async fn list(&self, account_id: &str) -> Result<Vec<ApiKeyRecord>, IdentityError> {
        let rows = self
            .store
            .bounded(
                sqlx::query_as::<_, ApiKeyDbRow>(
                    r#"
                    SELECT
                        keys.id,
                        keys.owner_account_id,
                        keys.name,
                        keys.raw_prefix AS label,
                        keys.key_hash,
                        NOT keys.active AS disabled,
                        keys.limit_micro_usd,
                        keys.limit_reset,
                        keys.rpm_limit,
                        keys.itpm_limit,
                        keys.otpm_limit,
                        keys.allowed_models,
                        keys.self_route_only,
                        CASE WHEN keys.expires_at IS NULL THEN NULL ELSE
                            to_char(keys.expires_at AT TIME ZONE 'UTC',
                                'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END AS expires_at,
                        to_char(keys.created_at AT TIME ZONE 'UTC',
                            'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS created_at,
                        CASE WHEN keys.last_used_at IS NULL THEN NULL ELSE
                            to_char(keys.last_used_at AT TIME ZONE 'UTC',
                                'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END AS last_used_at,
                        COALESCE((
                            SELECT SUM(usage.cost_micro_usd)
                            FROM public.usage
                            WHERE usage.key_id = keys.id
                              AND usage.created_at >= CASE keys.limit_reset
                                  WHEN 'daily' THEN date_trunc('day', NOW())
                                  WHEN 'weekly' THEN date_trunc('week', NOW())
                                  WHEN 'monthly' THEN date_trunc('month', NOW())
                                  ELSE '-infinity'::TIMESTAMPTZ
                              END
                        ), 0)::BIGINT AS usage_micro_usd
                    FROM public.api_keys AS keys
                    WHERE keys.owner_account_id = $1 AND keys.id <> ''
                    ORDER BY keys.created_at DESC
                    LIMIT 1000
                    "#,
                )
                .bind(account_id)
                .fetch_all(self.store.pool()),
            )
            .await?;
        rows.into_iter().map(ApiKeyDbRow::into_record).collect()
    }

    pub async fn get(&self, account_id: &str, id: &str) -> Result<ApiKeyRecord, IdentityError> {
        validate_public_id(id)?;
        let row = self
            .store
            .bounded(
                sqlx::query_as::<_, ApiKeyDbRow>(
                    r#"
                    SELECT
                        keys.id,
                        keys.owner_account_id,
                        keys.name,
                        keys.raw_prefix AS label,
                        keys.key_hash,
                        NOT keys.active AS disabled,
                        keys.limit_micro_usd,
                        keys.limit_reset,
                        keys.rpm_limit,
                        keys.itpm_limit,
                        keys.otpm_limit,
                        keys.allowed_models,
                        keys.self_route_only,
                        CASE WHEN keys.expires_at IS NULL THEN NULL ELSE
                            to_char(keys.expires_at AT TIME ZONE 'UTC',
                                'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END AS expires_at,
                        to_char(keys.created_at AT TIME ZONE 'UTC',
                            'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS created_at,
                        CASE WHEN keys.last_used_at IS NULL THEN NULL ELSE
                            to_char(keys.last_used_at AT TIME ZONE 'UTC',
                                'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END AS last_used_at,
                        COALESCE((
                            SELECT SUM(usage.cost_micro_usd)
                            FROM public.usage
                            WHERE usage.key_id = keys.id
                              AND usage.created_at >= CASE keys.limit_reset
                                  WHEN 'daily' THEN date_trunc('day', NOW())
                                  WHEN 'weekly' THEN date_trunc('week', NOW())
                                  WHEN 'monthly' THEN date_trunc('month', NOW())
                                  ELSE '-infinity'::TIMESTAMPTZ
                              END
                        ), 0)::BIGINT AS usage_micro_usd
                    FROM public.api_keys AS keys
                    WHERE keys.owner_account_id = $1 AND keys.id = $2
                    "#,
                )
                .bind(account_id)
                .bind(id)
                .fetch_optional(self.store.pool()),
            )
            .await?
            .ok_or_else(|| IdentityError::not_found("key not found"))?;
        row.into_record()
    }

    pub async fn authenticate(&self, raw: &str) -> Result<ApiKeyRecord, IdentityError> {
        validate_raw_secret(raw)?;
        let hash = hash_secret(raw);
        let row = self
            .store
            .bounded(
                sqlx::query_as::<_, ApiKeyDbRow>(
                    r#"
                    SELECT
                        keys.id,
                        keys.owner_account_id,
                        keys.name,
                        keys.raw_prefix AS label,
                        keys.key_hash,
                        NOT keys.active AS disabled,
                        keys.limit_micro_usd,
                        keys.limit_reset,
                        keys.rpm_limit,
                        keys.itpm_limit,
                        keys.otpm_limit,
                        keys.allowed_models,
                        keys.self_route_only,
                        CASE WHEN keys.expires_at IS NULL THEN NULL ELSE
                            to_char(keys.expires_at AT TIME ZONE 'UTC',
                                'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END AS expires_at,
                        to_char(keys.created_at AT TIME ZONE 'UTC',
                            'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS created_at,
                        CASE WHEN keys.last_used_at IS NULL THEN NULL ELSE
                            to_char(keys.last_used_at AT TIME ZONE 'UTC',
                                'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END AS last_used_at,
                        COALESCE((
                            SELECT SUM(usage.cost_micro_usd)
                            FROM public.usage
                            WHERE usage.key_id = keys.id
                              AND usage.created_at >= CASE keys.limit_reset
                                  WHEN 'daily' THEN date_trunc('day', NOW())
                                  WHEN 'weekly' THEN date_trunc('week', NOW())
                                  WHEN 'monthly' THEN date_trunc('month', NOW())
                                  ELSE '-infinity'::TIMESTAMPTZ
                              END
                        ), 0)::BIGINT AS usage_micro_usd
                    FROM public.api_keys AS keys
                    WHERE keys.key_hash = $1
                      AND keys.active = TRUE
                      AND (keys.expires_at IS NULL OR keys.expires_at > NOW())
                    "#,
                )
                .bind(&hash)
                .fetch_optional(self.store.pool()),
            )
            .await?;
        let Some(row) = row else {
            constant_time_secret_check(&hash, None);
            return Err(IdentityError::Unauthorized);
        };
        if !constant_time_secret_check(&hash, Some(&row.key_hash)) {
            return Err(IdentityError::Unauthorized);
        }
        row.into_record()
    }

    pub async fn patch(
        &self,
        account_id: &str,
        id: &str,
        patch: ApiKeyPatch,
    ) -> Result<ApiKeyRecord, IdentityError> {
        validate_public_id(id)?;
        let patch = patch.validate()?;
        let row = self
            .store
            .bounded(
                sqlx::query_as::<_, MutationKeyRow>(
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT EXISTS (
                            SELECT 1
                            FROM public.coordinator_ownership
                            WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                            FOR SHARE
                        ) AS ok
                    ), updated AS (
                        UPDATE public.api_keys AS keys SET
                            name = CASE WHEN $5 THEN $6 ELSE keys.name END,
                            active = CASE WHEN $7 THEN NOT $8 ELSE keys.active END,
                            limit_micro_usd = CASE WHEN $9 THEN $10 ELSE keys.limit_micro_usd END,
                            limit_reset = CASE WHEN $11 THEN $12 ELSE keys.limit_reset END,
                            rpm_limit = CASE WHEN $13 THEN $14 ELSE keys.rpm_limit END,
                            itpm_limit = CASE WHEN $15 THEN $16 ELSE keys.itpm_limit END,
                            otpm_limit = CASE WHEN $17 THEN $18 ELSE keys.otpm_limit END,
                            allowed_models = CASE WHEN $19 THEN $20 ELSE keys.allowed_models END,
                            self_route_only = CASE WHEN $21 THEN $22 ELSE keys.self_route_only END,
                            expires_at = CASE
                                WHEN $23 THEN $24::TIMESTAMPTZ
                                ELSE keys.expires_at
                            END
                        FROM authority
                        WHERE keys.owner_account_id = $3
                          AND keys.id = $4
                          AND authority.ok
                          AND (
                              NOT $23 OR $24::TEXT IS NULL OR $24::TIMESTAMPTZ > NOW()
                          )
                        RETURNING keys.*
                    )
                    SELECT
                        authority.ok AS authority_ok,
                        (NOT $23 OR $24::TEXT IS NULL OR $24::TIMESTAMPTZ > NOW()) AS expiry_ok,
                        updated.id,
                        updated.owner_account_id,
                        updated.name,
                        updated.raw_prefix AS label,
                        updated.key_hash,
                        NOT updated.active AS disabled,
                        updated.limit_micro_usd,
                        updated.limit_reset,
                        COALESCE((
                            SELECT SUM(usage.cost_micro_usd)
                            FROM public.usage
                            WHERE usage.key_id = updated.id
                              AND usage.created_at >= CASE updated.limit_reset
                                  WHEN 'daily' THEN date_trunc('day', NOW())
                                  WHEN 'weekly' THEN date_trunc('week', NOW())
                                  WHEN 'monthly' THEN date_trunc('month', NOW())
                                  ELSE '-infinity'::TIMESTAMPTZ
                              END
                        ), 0)::BIGINT AS usage_micro_usd,
                        updated.rpm_limit,
                        updated.itpm_limit,
                        updated.otpm_limit,
                        updated.allowed_models,
                        updated.self_route_only,
                        CASE WHEN updated.expires_at IS NULL THEN NULL ELSE
                            to_char(updated.expires_at AT TIME ZONE 'UTC',
                                'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END AS expires_at,
                        CASE WHEN updated.created_at IS NULL THEN NULL ELSE
                            to_char(updated.created_at AT TIME ZONE 'UTC',
                                'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END AS created_at,
                        CASE WHEN updated.last_used_at IS NULL THEN NULL ELSE
                            to_char(updated.last_used_at AT TIME ZONE 'UTC',
                                'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END AS last_used_at
                    FROM authority
                    LEFT JOIN updated ON TRUE
                    "#,
                )
                .bind(self.store.owner_id())
                .bind(self.store.epoch())
                .bind(account_id)
                .bind(id)
                .bind(patch.name.is_some())
                .bind(patch.name.as_deref().unwrap_or_default())
                .bind(patch.disabled.is_some())
                .bind(patch.disabled.unwrap_or(false))
                .bind(patch.limit_micro_usd.is_some())
                .bind(patch.limit_micro_usd.flatten())
                .bind(patch.limit_reset.is_some())
                .bind(patch.limit_reset.as_deref().unwrap_or("none"))
                .bind(patch.rpm_limit.is_some())
                .bind(patch.rpm_limit.flatten())
                .bind(patch.itpm_limit.is_some())
                .bind(patch.itpm_limit.flatten())
                .bind(patch.otpm_limit.is_some())
                .bind(patch.otpm_limit.flatten())
                .bind(patch.allowed_models_json.is_some())
                .bind(patch.allowed_models_json.as_deref().unwrap_or_default())
                .bind(patch.self_route_only.is_some())
                .bind(patch.self_route_only.unwrap_or(false))
                .bind(patch.expires_at.is_some())
                .bind(patch.expires_at.as_ref().and_then(|value| value.as_deref()))
                .fetch_one(self.store.pool()),
            )
            .await;
        match row {
            Ok(row) => row.into_record(),
            Err(IdentityError::Database(error)) if is_invalid_timestamp(&error) => Err(
                IdentityError::invalid("expires_at must be a valid RFC 3339 timestamp"),
            ),
            Err(error) => Err(error),
        }
    }

    pub async fn delete(&self, account_id: &str, id: &str) -> Result<(), IdentityError> {
        validate_public_id(id)?;
        let (authority_ok, deleted): (bool, bool) = self
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
                    ), deleted AS (
                        DELETE FROM public.api_keys AS keys
                        USING authority
                        WHERE keys.owner_account_id = $3
                          AND keys.id = $4
                          AND authority.ok
                        RETURNING 1
                    )
                    SELECT authority.ok, EXISTS (SELECT 1 FROM deleted)
                    FROM authority
                    "#,
                )
                .bind(self.store.owner_id())
                .bind(self.store.epoch())
                .bind(account_id)
                .bind(id)
                .fetch_one(self.store.pool()),
            )
            .await?;
        ensure_authority(authority_ok)?;
        if !deleted {
            return Err(IdentityError::not_found("key not found"));
        }
        Ok(())
    }

    pub async fn revoke_raw(&self, account_id: &str, raw: &str) -> Result<(), IdentityError> {
        validate_raw_secret(raw)?;
        let hash = hash_secret(raw);
        let (authority_ok, stored_hash): (bool, Option<String>) = self
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
                    ), revoked AS (
                        UPDATE public.api_keys AS keys
                        SET active = FALSE
                        FROM authority
                        WHERE keys.owner_account_id = $3
                          AND keys.key_hash = $4
                          AND authority.ok
                        RETURNING keys.key_hash
                    )
                    SELECT authority.ok, revoked.key_hash
                    FROM authority
                    LEFT JOIN revoked ON TRUE
                    "#,
                )
                .bind(self.store.owner_id())
                .bind(self.store.epoch())
                .bind(account_id)
                .bind(&hash)
                .fetch_one(self.store.pool()),
            )
            .await?;
        ensure_authority(authority_ok)?;
        if !constant_time_secret_check(&hash, stored_hash.as_deref()) {
            return Err(IdentityError::Forbidden);
        }
        Ok(())
    }

    pub async fn rotate(
        &self,
        account_id: &str,
        id: &str,
    ) -> Result<(String, ApiKeyRecord), IdentityError> {
        validate_public_id(id)?;
        for _ in 0..3 {
            let raw = generate_raw_key()?;
            let new_id = generate_key_id()?;
            let hash = hash_secret(&raw);
            let label = key_label(&raw);
            let row = self
                .store
                .bounded(
                    sqlx::query_as::<_, MutationKeyRow>(
                        r#"
                        WITH authority AS MATERIALIZED (
                            SELECT EXISTS (
                                SELECT 1 FROM public.coordinator_ownership
                                WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                            FOR SHARE
                            ) AS ok
                        ), removed AS (
                            DELETE FROM public.api_keys AS keys
                            USING authority
                            WHERE keys.owner_account_id = $3
                              AND keys.id = $4
                              AND authority.ok
                            RETURNING keys.*
                        ), inserted AS (
                            INSERT INTO public.api_keys (
                                id, key_hash, raw_prefix, owner_account_id, name, active,
                                limit_micro_usd, limit_reset, rpm_limit, itpm_limit, otpm_limit,
                                allowed_models, expires_at, created_at, self_route_only
                            )
                            SELECT
                                $5, $6, $7, removed.owner_account_id, removed.name, removed.active,
                                removed.limit_micro_usd, removed.limit_reset, removed.rpm_limit,
                                removed.itpm_limit, removed.otpm_limit, removed.allowed_models,
                                removed.expires_at, NOW(), removed.self_route_only
                            FROM removed
                            RETURNING *
                        )
                        SELECT
                            authority.ok AS authority_ok,
                            TRUE AS expiry_ok,
                            inserted.id,
                            inserted.owner_account_id,
                            inserted.name,
                            inserted.raw_prefix AS label,
                            inserted.key_hash,
                            NOT inserted.active AS disabled,
                            inserted.limit_micro_usd,
                            inserted.limit_reset,
                            0::BIGINT AS usage_micro_usd,
                            inserted.rpm_limit,
                            inserted.itpm_limit,
                            inserted.otpm_limit,
                            inserted.allowed_models,
                            inserted.self_route_only,
                            CASE WHEN inserted.expires_at IS NULL THEN NULL ELSE
                                to_char(inserted.expires_at AT TIME ZONE 'UTC',
                                    'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END AS expires_at,
                            CASE WHEN inserted.created_at IS NULL THEN NULL ELSE
                                to_char(inserted.created_at AT TIME ZONE 'UTC',
                                    'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END AS created_at,
                            NULL::TEXT AS last_used_at
                        FROM authority
                        LEFT JOIN inserted ON TRUE
                        "#,
                    )
                    .bind(self.store.owner_id())
                    .bind(self.store.epoch())
                    .bind(account_id)
                    .bind(id)
                    .bind(&new_id)
                    .bind(&hash)
                    .bind(&label)
                    .fetch_one(self.store.pool()),
                )
                .await;
            match row {
                Ok(row) => return Ok((raw, row.into_record()?)),
                Err(IdentityError::Database(error)) if is_unique_violation(&error) => continue,
                Err(error) => return Err(error),
            }
        }
        Err(IdentityError::Unavailable)
    }
}
