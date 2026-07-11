use std::sync::Arc;

use serde_json::Value;
use sqlx::FromRow;

use super::{
    error::IdentityError,
    store::IdentityStore,
    types::{
        DeleteProviderResponse, FleetCounts, IdentitySurfaceConfig, ProviderResponse,
        ProvidersResponse, ReputationResponse, SelfRouteModelsResponse, SummaryResponse,
    },
};

#[derive(Clone, Debug)]
pub struct AccountService {
    store: IdentityStore,
    config: Arc<IdentitySurfaceConfig>,
}

impl AccountService {
    pub fn new(store: IdentityStore, config: Arc<IdentitySurfaceConfig>) -> Self {
        Self { store, config }
    }

    pub async fn providers(&self, account_id: &str) -> Result<ProvidersResponse, IdentityError> {
        let rows = self
            .store
            .bounded(
                sqlx::query_as::<_, ProviderRow>(
                    r#"
                    WITH deduplicated AS (
                        SELECT DISTINCT ON (
                            COALESCE(NULLIF(providers.serial_number, ''),
                                     NULLIF(providers.se_public_key, ''),
                                     providers.id)
                        )
                            providers.*
                        FROM public.providers
                        WHERE providers.account_id = $1
                        ORDER BY
                            COALESCE(NULLIF(providers.serial_number, ''),
                                     NULLIF(providers.se_public_key, ''),
                                     providers.id),
                            providers.last_seen DESC
                    )
                    SELECT
                        deduplicated.id,
                        deduplicated.account_id,
                        CASE
                            WHEN deduplicated.trust_level = 'untrusted' THEN 'untrusted'
                            WHEN deduplicated.last_seen >=
                                NOW() - ($2::BIGINT * INTERVAL '1 second') THEN 'online'
                            ELSE 'offline'
                        END AS status,
                        deduplicated.trust_level <> 'untrusted'
                            AND deduplicated.last_seen >=
                                NOW() - ($2::BIGINT * INTERVAL '1 second') AS online,
                        CASE WHEN deduplicated.last_seen IS NULL THEN NULL ELSE
                            to_char(deduplicated.last_seen AT TIME ZONE 'UTC',
                                'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END AS last_heartbeat,
                        deduplicated.hardware,
                        deduplicated.models,
                        deduplicated.backend,
                        deduplicated.version,
                        deduplicated.serial_number,
                        deduplicated.trust_level,
                        deduplicated.attested,
                        deduplicated.mda_verified,
                        deduplicated.attestation_result,
                        deduplicated.mda_cert_chain,
                        deduplicated.se_public_key <> '' AS se_key_bound,
                        deduplicated.se_public_key,
                        deduplicated.public_key AS provider_key,
                        deduplicated.runtime_verified,
                        deduplicated.python_hash,
                        deduplicated.runtime_hash,
                        CASE WHEN deduplicated.last_challenge_verified IS NULL THEN NULL ELSE
                            to_char(deduplicated.last_challenge_verified AT TIME ZONE 'UTC',
                                'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END AS last_challenge_verified,
                        deduplicated.failed_challenges,
                        COALESCE(reputation.total_jobs, 0) AS total_jobs,
                        COALESCE(reputation.successful_jobs, 0) AS successful_jobs,
                        COALESCE(reputation.failed_jobs, 0) AS failed_jobs,
                        COALESCE(reputation.total_uptime_seconds, 0) AS total_uptime_seconds,
                        COALESCE(reputation.avg_response_time_ms, 0) AS avg_response_time_ms,
                        COALESCE(reputation.challenges_passed, 0) AS challenges_passed,
                        COALESCE(reputation.challenges_failed, 0) AS challenges_failed,
                        deduplicated.lifetime_requests_served,
                        deduplicated.lifetime_tokens_generated,
                        to_char(deduplicated.registered_at AT TIME ZONE 'UTC',
                            'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS registered_at,
                        to_char(deduplicated.last_seen AT TIME ZONE 'UTC',
                            'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS last_seen
                    FROM deduplicated
                    LEFT JOIN public.provider_reputation AS reputation
                        ON reputation.provider_id = deduplicated.id
                    ORDER BY deduplicated.last_seen DESC
                    LIMIT 1000
                    "#,
                )
                .bind(account_id)
                .bind(duration_seconds_i64(self.config.heartbeat_timeout))
                .fetch_all(self.store.pool()),
            )
            .await?;
        Ok(ProvidersResponse {
            providers: rows.into_iter().map(ProviderRow::into_response).collect(),
            latest_provider_version: Arc::clone(&self.config.latest_provider_version),
            min_provider_version: Arc::clone(&self.config.minimum_provider_version),
            heartbeat_timeout_seconds: self.config.heartbeat_timeout.as_secs(),
            challenge_max_age_seconds: self.config.challenge_max_age.as_secs(),
        })
    }

    pub async fn summary(
        &self,
        account_id: Arc<str>,
        payout_ready: bool,
    ) -> Result<SummaryResponse, IdentityError> {
        let row = self
            .store
            .bounded(
                sqlx::query_as::<_, SummaryRow>(
                    r#"
                    WITH deduplicated AS (
                        SELECT DISTINCT ON (
                            COALESCE(NULLIF(providers.serial_number, ''),
                                     NULLIF(providers.se_public_key, ''),
                                     providers.id)
                        )
                            providers.*
                        FROM public.providers
                        WHERE providers.account_id = $1
                        ORDER BY
                            COALESCE(NULLIF(providers.serial_number, ''),
                                     NULLIF(providers.se_public_key, ''),
                                     providers.id),
                            providers.last_seen DESC
                    ), fleet AS (
                        SELECT
                            COUNT(*)::BIGINT AS total,
                            COUNT(*) FILTER (
                                WHERE trust_level <> 'untrusted'
                                  AND last_seen >= NOW() - ($2::BIGINT * INTERVAL '1 second')
                            )::BIGINT AS online,
                            0::BIGINT AS serving,
                            COUNT(*) FILTER (
                                WHERE trust_level <> 'untrusted'
                                  AND last_seen < NOW() - ($2::BIGINT * INTERVAL '1 second')
                            )::BIGINT AS offline,
                            COUNT(*) FILTER (WHERE trust_level = 'untrusted')::BIGINT AS untrusted,
                            COUNT(*) FILTER (WHERE trust_level = 'hardware')::BIGINT AS hardware,
                            COUNT(*) FILTER (
                                WHERE trust_level <> 'hardware'
                                   OR trust_level = 'untrusted'
                                   OR NOT runtime_verified
                                   OR failed_challenges > 0
                                   OR last_seen < NOW() - ($2::BIGINT * INTERVAL '1 second')
                            )::BIGINT AS needs_attention
                        FROM deduplicated
                    ), recent AS (
                        SELECT
                            COALESCE(SUM(amount_micro_usd) FILTER (
                                WHERE created_at >= NOW() - INTERVAL '24 hours'
                            ), 0)::BIGINT AS last_24h_micro_usd,
                            COUNT(*) FILTER (
                                WHERE created_at >= NOW() - INTERVAL '24 hours'
                            )::BIGINT AS last_24h_jobs,
                            COALESCE(SUM(amount_micro_usd) FILTER (
                                WHERE created_at >= NOW() - INTERVAL '7 days'
                            ), 0)::BIGINT AS last_7d_micro_usd,
                            COUNT(*) FILTER (
                                WHERE created_at >= NOW() - INTERVAL '7 days'
                            )::BIGINT AS last_7d_jobs
                        FROM public.provider_earnings
                        WHERE account_id = $1
                          AND created_at >= NOW() - INTERVAL '7 days'
                    )
                    SELECT
                        COALESCE(balances.balance_micro_usd, 0)::BIGINT
                            AS available_balance_micro_usd,
                        COALESCE(balances.withdrawable_micro_usd, 0)::BIGINT
                            AS withdrawable_balance_micro_usd,
                        COALESCE(summary.total_micro_usd, 0)::BIGINT AS lifetime_micro_usd,
                        COALESCE(summary.total_count, 0)::BIGINT AS lifetime_jobs,
                        recent.last_24h_micro_usd,
                        recent.last_24h_jobs,
                        recent.last_7d_micro_usd,
                        recent.last_7d_jobs,
                        fleet.total,
                        fleet.online,
                        fleet.serving,
                        fleet.offline,
                        fleet.untrusted,
                        fleet.hardware,
                        fleet.needs_attention
                    FROM fleet
                    CROSS JOIN recent
                    LEFT JOIN public.balances AS balances ON balances.account_id = $1
                    LEFT JOIN public.earnings_summary AS summary
                        ON summary.key = $1 AND summary.key_type = 'account'
                    "#,
                )
                .bind(account_id.as_ref())
                .bind(duration_seconds_i64(self.config.heartbeat_timeout))
                .fetch_one(self.store.pool()),
            )
            .await?;
        Ok(SummaryResponse {
            account_id,
            available_balance_micro_usd: row.available_balance_micro_usd,
            withdrawable_balance_micro_usd: row.withdrawable_balance_micro_usd,
            payout_ready,
            lifetime_micro_usd: row.lifetime_micro_usd,
            lifetime_jobs: row.lifetime_jobs,
            last_24h_micro_usd: row.last_24h_micro_usd,
            last_24h_jobs: row.last_24h_jobs,
            last_7d_micro_usd: row.last_7d_micro_usd,
            last_7d_jobs: row.last_7d_jobs,
            counts: FleetCounts {
                total: row.total,
                online: row.online,
                serving: row.serving,
                offline: row.offline,
                untrusted: row.untrusted,
                hardware: row.hardware,
                needs_attention: row.needs_attention,
            },
            latest_provider_version: Arc::clone(&self.config.latest_provider_version),
            min_provider_version: Arc::clone(&self.config.minimum_provider_version),
        })
    }

    pub async fn self_route_models(
        &self,
        account_id: &str,
    ) -> Result<SelfRouteModelsResponse, IdentityError> {
        let models = self
            .store
            .bounded(
                sqlx::query_scalar::<_, String>(
                    r#"
                    WITH advertised AS (
                        SELECT DISTINCT model.value AS model
                        FROM public.providers AS providers
                        CROSS JOIN LATERAL jsonb_array_elements(
                            CASE
                                WHEN jsonb_typeof(providers.models) = 'array'
                                    THEN providers.models
                                ELSE '[]'::JSONB
                            END
                        ) AS model(value)
                        WHERE providers.account_id = $1
                          AND providers.trust_level <> 'untrusted'
                          AND providers.runtime_verified
                          AND providers.last_seen >=
                              NOW() - ($2::BIGINT * INTERVAL '1 second')
                          AND providers.last_challenge_verified IS NOT NULL
                          AND providers.last_challenge_verified >=
                              NOW() - ($3::BIGINT * INTERVAL '1 second')
                          AND jsonb_typeof(model.value) = 'object'
                          AND COALESCE(model.value->>'id', '') <> ''
                          AND (
                              NOT model.value ? 'template_render_ok'
                              OR model.value->>'template_render_ok' = 'true'
                          )
                    ), servable AS (
                        SELECT DISTINCT advertised.model->>'id' AS id
                        FROM advertised
                        LEFT JOIN public.model_registry AS registry
                            ON registry.id = advertised.model->>'id'
                        LEFT JOIN public.model_active_versions AS active
                            ON active.model_id = registry.id
                        LEFT JOIN public.model_versions AS version
                            ON version.id = active.model_version_id
                        WHERE registry.id IS NULL
                           OR COALESCE(advertised.model->>'weight_hash', '') = ''
                           OR COALESCE(advertised.model->>'weight_hash', '') =
                              COALESCE(version.aggregate_sha256, '')
                    ), visible_aliases AS (
                        SELECT DISTINCT aliases.alias_id
                        FROM public.model_aliases AS aliases
                        JOIN servable
                          ON servable.id = aliases.desired_build
                          OR (aliases.previous_build <> ''
                              AND servable.id = aliases.previous_build)
                        WHERE aliases.active AND aliases.desired_build <> ''
                    ), covered AS (
                        SELECT aliases.desired_build AS id
                        FROM public.model_aliases AS aliases
                        JOIN visible_aliases ON visible_aliases.alias_id = aliases.alias_id
                        UNION
                        SELECT aliases.previous_build AS id
                        FROM public.model_aliases AS aliases
                        JOIN visible_aliases ON visible_aliases.alias_id = aliases.alias_id
                        WHERE aliases.previous_build <> ''
                    )
                    SELECT alias_id AS id FROM visible_aliases
                    UNION
                    SELECT servable.id
                    FROM servable
                    WHERE NOT EXISTS (
                        SELECT 1 FROM covered WHERE covered.id = servable.id
                    )
                    ORDER BY id
                    LIMIT 1000
                    "#,
                )
                .bind(account_id)
                .bind(duration_seconds_i64(self.config.heartbeat_timeout))
                .bind(duration_seconds_i64(self.config.challenge_max_age))
                .fetch_all(self.store.pool()),
            )
            .await?;
        Ok(SelfRouteModelsResponse { models })
    }

    pub async fn delete_provider(
        &self,
        account_id: &str,
        serial_or_id: &str,
    ) -> Result<DeleteProviderResponse, IdentityError> {
        let serial_or_id = serial_or_id.trim();
        if serial_or_id.is_empty()
            || serial_or_id.len() > 256
            || serial_or_id.bytes().any(|byte| byte.is_ascii_control())
        {
            return Err(IdentityError::invalid("missing or invalid serial"));
        }
        let row = self
            .store
            .bounded(
                sqlx::query_as::<_, DeleteProviderRow>(
                    r#"
                    WITH authority AS MATERIALIZED (
                        SELECT EXISTS (
                            SELECT 1 FROM public.coordinator_ownership
                            WHERE singleton = TRUE AND owner_id = $1 AND epoch = $2
                            FOR SHARE
                        ) AS ok
                    ), located AS MATERIALIZED (
                        SELECT providers.id, providers.account_id, providers.last_seen
                        FROM public.providers AS providers
                        WHERE (
                              (providers.serial_number = $4
                               AND providers.serial_number <> '')
                              OR providers.id = $4
                          )
                        FOR UPDATE
                    ), matched AS MATERIALIZED (
                        SELECT located.id, located.last_seen
                        FROM located, authority
                        WHERE located.account_id = $3
                          AND authority.ok
                    ), state AS MATERIALIZED (
                        SELECT
                            EXISTS (SELECT 1 FROM located) AS found,
                            EXISTS (SELECT 1 FROM matched) AS owned,
                            EXISTS (
                                SELECT 1 FROM matched
                                WHERE last_seen >=
                                    NOW() - ($5::BIGINT * INTERVAL '1 second')
                            ) AS online
                    ), reputations AS (
                        DELETE FROM public.provider_reputation AS reputation
                        USING matched, state
                        WHERE reputation.provider_id = matched.id
                          AND NOT state.online
                        RETURNING reputation.provider_id
                    ), deleted AS (
                        DELETE FROM public.providers AS providers
                        USING matched, state
                        WHERE providers.id = matched.id
                          AND providers.account_id = $3
                          AND NOT state.online
                          AND (SELECT COUNT(*) FROM reputations) >= 0
                        RETURNING providers.id
                    )
                    SELECT
                        authority.ok AS authority_ok,
                        state.found,
                        state.owned,
                        state.online,
                        (SELECT COUNT(*) FROM deleted)::BIGINT AS rows_removed
                    FROM authority
                    CROSS JOIN state
                    "#,
                )
                .bind(self.store.owner_id())
                .bind(self.store.epoch())
                .bind(account_id)
                .bind(serial_or_id)
                .bind(duration_seconds_i64(self.config.heartbeat_timeout))
                .fetch_one(self.store.pool()),
            )
            .await?;
        if !row.authority_ok {
            return Err(IdentityError::OwnershipUnavailable);
        }
        if !row.found {
            return Err(IdentityError::not_found("machine not found"));
        }
        if !row.owned {
            return Err(IdentityError::Forbidden);
        }
        if row.online {
            return Err(IdentityError::conflict(
                "machine is currently online; stop it before removing",
            ));
        }
        if row.rows_removed == 0 {
            return Err(IdentityError::not_found("machine not found"));
        }
        Ok(DeleteProviderResponse {
            deleted: true,
            serial: serial_or_id.to_owned(),
            rows_removed: row.rows_removed,
        })
    }
}

#[derive(FromRow)]
struct ProviderRow {
    id: String,
    account_id: String,
    status: String,
    online: bool,
    last_heartbeat: Option<String>,
    hardware: Value,
    models: Value,
    backend: String,
    version: String,
    serial_number: String,
    trust_level: String,
    attested: bool,
    mda_verified: bool,
    attestation_result: Option<Value>,
    mda_cert_chain: Option<Value>,
    se_key_bound: bool,
    se_public_key: String,
    provider_key: String,
    runtime_verified: bool,
    python_hash: String,
    runtime_hash: String,
    last_challenge_verified: Option<String>,
    failed_challenges: i32,
    total_jobs: i32,
    successful_jobs: i32,
    failed_jobs: i32,
    total_uptime_seconds: i64,
    avg_response_time_ms: i64,
    challenges_passed: i32,
    challenges_failed: i32,
    lifetime_requests_served: i64,
    lifetime_tokens_generated: i64,
    registered_at: Option<String>,
    last_seen: Option<String>,
}

impl ProviderRow {
    fn into_response(self) -> ProviderResponse {
        let secure_enclave = attestation_bool(
            self.attestation_result.as_ref(),
            "SecureEnclaveAvailable",
            "secure_enclave_available",
        );
        let sip_enabled = attestation_bool(
            self.attestation_result.as_ref(),
            "SIPEnabled",
            "sip_enabled",
        );
        let secure_boot_enabled = attestation_bool(
            self.attestation_result.as_ref(),
            "SecureBootEnabled",
            "secure_boot_enabled",
        );
        let authenticated_root_enabled = attestation_bool(
            self.attestation_result.as_ref(),
            "AuthenticatedRootEnabled",
            "authenticated_root_enabled",
        );
        let system_volume_hash = attestation_string(
            self.attestation_result.as_ref(),
            "SystemVolumeHash",
            "system_volume_hash",
        );
        let mda_cert_chain_b64 = json_string_array(self.mda_cert_chain.as_ref());
        let reputation = ReputationResponse {
            score: reputation_score(
                self.total_jobs,
                self.successful_jobs,
                self.total_uptime_seconds,
                self.avg_response_time_ms,
                self.challenges_passed,
                self.challenges_failed,
            ),
            total_jobs: self.total_jobs,
            successful_jobs: self.successful_jobs,
            failed_jobs: self.failed_jobs,
            total_uptime_seconds: self.total_uptime_seconds,
            avg_response_time_ms: self.avg_response_time_ms,
            challenges_passed: self.challenges_passed,
            challenges_failed: self.challenges_failed,
        };
        ProviderResponse {
            id: self.id,
            account_id: self.account_id,
            status: self.status,
            online: self.online,
            last_heartbeat: self.last_heartbeat,
            hardware: self.hardware,
            models: self.models,
            backend: self.backend,
            version: self.version,
            serial_number: self.serial_number,
            trust_level: self.trust_level,
            attested: self.attested,
            mda_verified: self.mda_verified,
            acme_verified: false,
            se_key_bound: self.se_key_bound,
            se_public_key: self.se_public_key,
            provider_key: self.provider_key,
            secure_enclave,
            sip_enabled,
            secure_boot_enabled,
            authenticated_root_enabled,
            system_volume_hash,
            mda_cert_chain_b64,
            runtime_verified: self.runtime_verified,
            python_hash: self.python_hash,
            runtime_hash: self.runtime_hash,
            last_challenge_verified: self.last_challenge_verified,
            failed_challenges: self.failed_challenges,
            reputation,
            lifetime_requests_served: self.lifetime_requests_served,
            lifetime_tokens_generated: self.lifetime_tokens_generated,
            pending_requests: 0,
            max_concurrency: 0,
            registered_at: self.registered_at,
            last_seen: self.last_seen,
        }
    }
}

#[derive(FromRow)]
struct SummaryRow {
    available_balance_micro_usd: i64,
    withdrawable_balance_micro_usd: i64,
    lifetime_micro_usd: i64,
    lifetime_jobs: i64,
    last_24h_micro_usd: i64,
    last_24h_jobs: i64,
    last_7d_micro_usd: i64,
    last_7d_jobs: i64,
    total: i64,
    online: i64,
    serving: i64,
    offline: i64,
    untrusted: i64,
    hardware: i64,
    needs_attention: i64,
}

#[derive(FromRow)]
struct DeleteProviderRow {
    authority_ok: bool,
    found: bool,
    owned: bool,
    online: bool,
    rows_removed: i64,
}

fn attestation_bool(value: Option<&Value>, go_name: &str, wire_name: &str) -> bool {
    value
        .and_then(|value| value.get(go_name).or_else(|| value.get(wire_name)))
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

fn attestation_string(value: Option<&Value>, go_name: &str, wire_name: &str) -> String {
    value
        .and_then(|value| value.get(go_name).or_else(|| value.get(wire_name)))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned()
}

fn json_string_array(value: Option<&Value>) -> Vec<String> {
    value
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .map(ToOwned::to_owned)
                .collect()
        })
        .unwrap_or_default()
}

fn reputation_score(
    total_jobs: i32,
    successful_jobs: i32,
    uptime_seconds: i64,
    average_response_ms: i64,
    challenges_passed: i32,
    challenges_failed: i32,
) -> f64 {
    if total_jobs == 0 && challenges_passed == 0 && challenges_failed == 0 {
        return 0.5;
    }
    let job_rate = if total_jobs > 0 {
        f64::from(successful_jobs) / f64::from(total_jobs)
    } else {
        0.5
    };
    let uptime_rate = ((uptime_seconds as f64 / 86_400.0).clamp(0.5, 1.0)).max(0.5);
    let total_challenges = challenges_passed.saturating_add(challenges_failed);
    let challenge_rate = if total_challenges > 0 {
        f64::from(challenges_passed) / f64::from(total_challenges)
    } else {
        0.5
    };
    let response_rate = if successful_jobs <= 0 || average_response_ms <= 0 {
        0.5
    } else if average_response_ms <= 1000 {
        1.0
    } else if average_response_ms >= 10_000 {
        0.0
    } else {
        1.0 - (average_response_ms as f64 - 1000.0) / 9000.0
    };
    (0.4 * job_rate + 0.3 * uptime_rate + 0.2 * challenge_rate + 0.1 * response_rate)
        .clamp(0.0, 1.0)
}

fn duration_seconds_i64(duration: std::time::Duration) -> i64 {
    i64::try_from(duration.as_secs()).unwrap_or(i64::MAX)
}
