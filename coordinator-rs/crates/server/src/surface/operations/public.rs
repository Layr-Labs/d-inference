use std::{collections::BTreeMap, sync::Arc};

use axum::{
    Json,
    extract::{Query, State},
    http::HeaderMap,
};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::{Row, types::Json as SqlJson};

use super::{OperationsState, auth::require_public, error::OperationsError};

const DEFAULT_LEADERBOARD_LIMIT: i64 = 50;
const MAX_LEADERBOARD_LIMIT: i64 = 200;

#[derive(Debug, Deserialize)]
pub(super) struct WindowQuery {
    window: Option<String>,
    metric: Option<String>,
    limit: Option<i64>,
}

pub(super) async fn stats(
    State(state): State<Arc<OperationsState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, OperationsError> {
    require_public(&state.auth, &headers)?;
    let fleet = state.pilot().map(|pilot| pilot.fleet_snapshot());
    let live_ids = fleet
        .iter()
        .flat_map(|snapshot| snapshot.providers())
        .map(|provider| provider.provider().fence().provider_id.to_string())
        .collect::<Vec<_>>();
    let persisted = persisted_provider_data(state.pool(), &live_ids).await?;

    let mut models = BTreeMap::<String, usize>::new();
    let providers = fleet
        .iter()
        .flat_map(|snapshot| snapshot.providers())
        .map(|runtime| {
            let provider = runtime.provider();
            let fence = provider.fence();
            let capacity = provider.capacity();
            let provider_id = fence.provider_id.to_string();
            let persisted = persisted.get(&provider_id);
            *models.entry(fence.model_id.to_string()).or_default() += 1;
            json!({
                "id": provider_id,
                "model": fence.model_id.to_string(),
                "hardware_class": provider.hardware().to_string(),
                "health": provider.health(),
                "trust_revision": fence.trust_revision.get(),
                "session_revision": fence.session_revision.get(),
                "model_revision": fence.model_revision.get(),
                "active_leases": runtime.active_leases(),
                "heartbeat_sequence": runtime.heartbeat_sequence(),
                "writer_items": runtime.effective_writer_items(),
                "writer_bytes": runtime.effective_writer_bytes(),
                "token_capacity": capacity.token_capacity().get(),
                "tokens_in_use": capacity.tokens_in_use().get(),
                "kv_capacity_bytes": capacity.kv_capacity().get(),
                "kv_in_use_bytes": capacity.kv_in_use().get(),
                "concurrency_limit": capacity.concurrency_limit(),
                "concurrency_in_use": capacity.concurrency_in_use(),
                "hardware": persisted.and_then(|value| value.get("hardware")).cloned(),
                "trust_level": persisted.and_then(|value| value.get("trust_level")).cloned(),
                "attested": persisted.and_then(|value| value.get("attested")).cloned(),
                "mda_verified": persisted.and_then(|value| value.get("mda_verified")).cloned(),
                "runtime_verified": persisted.and_then(|value| value.get("runtime_verified")).cloned(),
                "version": persisted.and_then(|value| value.get("version")).cloned(),
            })
        })
        .collect::<Vec<_>>();
    let models = models
        .into_iter()
        .map(|(id, providers)| json!({"id": id, "providers": providers}))
        .collect::<Vec<_>>();

    let totals = sqlx::query(
        r#"
        SELECT total_requests, total_prompt_tokens, total_completion_tokens
        FROM public.usage_totals WHERE id=1
        "#,
    )
    .fetch_optional(state.pool())
    .await
    .map_err(|error| OperationsError::internal("load usage totals", error))?;
    let (total_requests, prompt_tokens, completion_tokens) = totals.map_or((0, 0, 0), |row| {
        (
            row.get::<i64, _>("total_requests"),
            row.get::<i64, _>("total_prompt_tokens"),
            row.get::<i64, _>("total_completion_tokens"),
        )
    });
    let series = sqlx::query(
        r#"
        SELECT
            to_char(date_trunc('minute', created_at) AT TIME ZONE 'UTC',
                    'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS timestamp,
            COUNT(*)::BIGINT AS requests,
            COALESCE(SUM(prompt_tokens),0)::BIGINT AS prompt_tokens,
            COALESCE(SUM(completion_tokens),0)::BIGINT AS completion_tokens
        FROM public.usage
        WHERE created_at >= NOW() - INTERVAL '30 minutes'
        GROUP BY date_trunc('minute', created_at)
        ORDER BY date_trunc('minute', created_at)
        "#,
    )
    .fetch_all(state.pool())
    .await
    .map_err(|error| OperationsError::internal("load usage time series", error))?
    .into_iter()
    .map(|row| {
        let prompt = row.get::<i64, _>("prompt_tokens");
        let completion = row.get::<i64, _>("completion_tokens");
        json!({
            "timestamp": row.get::<String, _>("timestamp"),
            "requests": row.get::<i64, _>("requests"),
            "prompt_tokens": prompt,
            "completion_tokens": completion,
            "total_tokens": prompt.saturating_add(completion),
        })
    })
    .collect::<Vec<_>>();
    let total_tokens = prompt_tokens.saturating_add(completion_tokens);
    let average = if total_requests == 0 {
        0.0
    } else {
        total_tokens as f64 / total_requests as f64
    };
    let fleet_revision = fleet
        .as_ref()
        .map_or(0, |snapshot| snapshot.revision().get());
    Ok(Json(json!({
        "total_requests": total_requests,
        "total_prompt_tokens": prompt_tokens,
        "total_completion_tokens": completion_tokens,
        "total_tokens": total_tokens,
        "avg_tokens_per_request": average,
        "active_providers": providers.len(),
        "active_leases": fleet.as_ref().map_or(0, |snapshot| snapshot.active_lease_count()),
        "fleet_revision": fleet_revision,
        "providers": providers,
        "models": models,
        "time_series": series,
        "draining": state.is_draining(),
    })))
}

pub(super) async fn leaderboard(
    State(state): State<Arc<OperationsState>>,
    headers: HeaderMap,
    Query(query): Query<WindowQuery>,
) -> Result<Json<Value>, OperationsError> {
    require_public(&state.auth, &headers)?;
    let metric = query.metric.as_deref().unwrap_or("earnings");
    match metric {
        "earnings" | "tokens" | "jobs" => {}
        _ => {
            return Err(OperationsError::bad_request(
                "metric must be one of: earnings, tokens, jobs",
            ));
        }
    }
    let (window, seconds) = parse_window(query.window.as_deref())?;
    let limit = query
        .limit
        .filter(|limit| (1..=MAX_LEADERBOARD_LIMIT).contains(limit))
        .unwrap_or(DEFAULT_LEADERBOARD_LIMIT);
    let rows = sqlx::query(
        r#"
        WITH work AS (
            SELECT account_id,
                   COALESCE(SUM(amount_micro_usd),0)::BIGINT AS work_micro_usd,
                   COALESCE(SUM(prompt_tokens + completion_tokens),0)::BIGINT AS tokens,
                   COUNT(*)::BIGINT AS jobs
            FROM public.provider_earnings
            WHERE account_id <> '' AND model <> 'base_reward'
              AND ($1::BIGINT IS NULL OR created_at >= NOW() - ($1 * INTERVAL '1 second'))
            GROUP BY account_id
        ), reward AS (
            SELECT provider.account_id,
                   COALESCE(base.amount,0)::BIGINT + COALESCE(ledger.amount,0)::BIGINT
                       AS reward_micro_usd
            FROM (
                SELECT DISTINCT account_id FROM public.provider_earnings
                WHERE account_id <> ''
                  AND ($1::BIGINT IS NULL OR created_at >= NOW() - ($1 * INTERVAL '1 second'))
            ) provider
            LEFT JOIN (
                SELECT account_id, SUM(amount_micro_usd)::BIGINT AS amount
                FROM public.provider_earnings
                WHERE model='base_reward'
                  AND ($1::BIGINT IS NULL OR created_at >= NOW() - ($1 * INTERVAL '1 second'))
                GROUP BY account_id
            ) base USING (account_id)
            LEFT JOIN (
                SELECT account_id, SUM(amount_micro_usd)::BIGINT AS amount
                FROM public.ledger_entries
                WHERE entry_type IN ('referral_reward','admin_reward')
                  AND ($1::BIGINT IS NULL OR created_at >= NOW() - ($1 * INTERVAL '1 second'))
                GROUP BY account_id
            ) ledger USING (account_id)
        )
        SELECT COALESCE(work.account_id,reward.account_id) AS account_id,
               COALESCE(work.work_micro_usd,0) + COALESCE(reward.reward_micro_usd,0)
                   AS earnings_micro_usd,
               COALESCE(work.work_micro_usd,0) AS work_earnings_micro_usd,
               COALESCE(reward.reward_micro_usd,0) AS reward_earnings_micro_usd,
               COALESCE(work.tokens,0) AS tokens,
               COALESCE(work.jobs,0) AS jobs
        FROM work FULL OUTER JOIN reward USING (account_id)
        ORDER BY
            CASE WHEN $2 = 'earnings' THEN
                COALESCE(work.work_micro_usd,0) + COALESCE(reward.reward_micro_usd,0)
            END DESC,
            CASE WHEN $2 = 'tokens' THEN COALESCE(work.tokens,0) END DESC,
            CASE WHEN $2 = 'jobs' THEN COALESCE(work.jobs,0) END DESC,
            account_id
        LIMIT $3
        "#,
    )
    .bind(seconds)
    .bind(metric)
    .bind(limit)
    .fetch_all(state.pool())
    .await
    .map_err(|error| OperationsError::internal("load leaderboard", error))?;
    let entries = rows
        .into_iter()
        .enumerate()
        .map(|(index, row)| {
            json!({
                "rank": index + 1,
                "pseudonym": pseudonym(&row.get::<String, _>("account_id")),
                "earnings_micro_usd": row.get::<i64, _>("earnings_micro_usd"),
                "work_earnings_micro_usd": row.get::<i64, _>("work_earnings_micro_usd"),
                "reward_earnings_micro_usd": row.get::<i64, _>("reward_earnings_micro_usd"),
                "tokens": row.get::<i64, _>("tokens"),
                "jobs": row.get::<i64, _>("jobs"),
            })
        })
        .collect::<Vec<_>>();
    Ok(Json(json!({
        "metric": metric,
        "window": window,
        "entries": entries,
        "updated_at": database_now(state.pool()).await?,
    })))
}

pub(super) async fn network_totals(
    State(state): State<Arc<OperationsState>>,
    headers: HeaderMap,
    Query(query): Query<WindowQuery>,
) -> Result<Json<Value>, OperationsError> {
    require_public(&state.auth, &headers)?;
    let (window, seconds) = parse_window(query.window.as_deref())?;
    let row = sqlx::query(
        r#"
        WITH work AS (
            SELECT COALESCE(SUM(amount_micro_usd),0)::BIGINT AS amount,
                   COALESCE(SUM(prompt_tokens + completion_tokens),0)::BIGINT AS tokens,
                   COUNT(*)::BIGINT AS jobs
            FROM public.provider_earnings
            WHERE model <> 'base_reward'
              AND ($1::BIGINT IS NULL OR created_at >= NOW() - ($1 * INTERVAL '1 second'))
        ), provider_accounts AS (
            SELECT DISTINCT account_id
            FROM public.provider_earnings
            WHERE account_id <> ''
              AND ($1::BIGINT IS NULL OR created_at >= NOW() - ($1 * INTERVAL '1 second'))
        ), rewards AS (
            SELECT
              COALESCE((
                SELECT SUM(amount_micro_usd) FROM public.provider_earnings
                WHERE model='base_reward'
                  AND ($1::BIGINT IS NULL OR created_at >= NOW() - ($1 * INTERVAL '1 second'))
              ),0)::BIGINT
              + COALESCE((
                SELECT SUM(entries.amount_micro_usd)
                FROM public.ledger_entries entries
                JOIN provider_accounts providers USING (account_id)
                WHERE entries.entry_type IN ('referral_reward','admin_reward')
                  AND ($1::BIGINT IS NULL OR entries.created_at >= NOW() - ($1 * INTERVAL '1 second'))
              ),0)::BIGINT AS amount
        )
        SELECT work.amount + rewards.amount AS earnings_micro_usd,
               work.amount AS work_earnings_micro_usd,
               rewards.amount AS reward_earnings_micro_usd,
               work.tokens, work.jobs,
               (SELECT COUNT(*)::BIGINT FROM provider_accounts) AS active_accounts
        FROM work, rewards
        "#,
    )
    .bind(seconds)
    .fetch_one(state.pool())
    .await
    .map_err(|error| OperationsError::internal("load network totals", error))?;
    Ok(Json(json!({
        "window": window,
        "earnings_micro_usd": row.get::<i64, _>("earnings_micro_usd"),
        "work_earnings_micro_usd": row.get::<i64, _>("work_earnings_micro_usd"),
        "reward_earnings_micro_usd": row.get::<i64, _>("reward_earnings_micro_usd"),
        "tokens": row.get::<i64, _>("tokens"),
        "jobs": row.get::<i64, _>("jobs"),
        "active_accounts": row.get::<i64, _>("active_accounts"),
        "updated_at": database_now(state.pool()).await?,
    })))
}

pub(super) async fn network_series(
    State(state): State<Arc<OperationsState>>,
    headers: HeaderMap,
    Query(query): Query<WindowQuery>,
) -> Result<Json<Value>, OperationsError> {
    require_public(&state.auth, &headers)?;
    let (window, duration_seconds, bucket_seconds) =
        parse_network_series_window(query.window.as_deref())?;
    let bounds = sqlx::query(
        r#"
        WITH bounds AS (
            SELECT date_bin(
                $1::BIGINT * INTERVAL '1 second',
                NOW(),
                TIMESTAMPTZ '1970-01-01 00:00:00+00'
            ) AS end_at
        )
        SELECT
            to_char(
                (end_at - $2::BIGINT * INTERVAL '1 second') AT TIME ZONE 'UTC',
                'YYYY-MM-DD"T"HH24:MI:SS"Z"'
            ) AS start_at,
            to_char(
                end_at AT TIME ZONE 'UTC',
                'YYYY-MM-DD"T"HH24:MI:SS"Z"'
            ) AS end_at,
            extract(epoch FROM end_at)::BIGINT AS end_epoch
        FROM bounds
        "#,
    )
    .bind(bucket_seconds)
    .bind(duration_seconds)
    .fetch_one(state.pool())
    .await
    .map_err(|error| OperationsError::internal("load network series bounds", error))?;
    let start_at = bounds.get::<String, _>("start_at");
    let end_at = bounds.get::<String, _>("end_at");
    let end_epoch = bounds.get::<i64, _>("end_epoch");
    let rows = sqlx::query(
        r#"
        WITH bounds AS (
            SELECT to_timestamp($3::DOUBLE PRECISION) AS end_at
        )
        SELECT
            to_char(
                to_timestamp(
                    floor(
                        extract(epoch FROM usage.created_at)
                        / $1::DOUBLE PRECISION
                    ) * $1::DOUBLE PRECISION
                ) AT TIME ZONE 'UTC',
                'YYYY-MM-DD"T"HH24:MI:SS"Z"'
            ) AS timestamp,
            COUNT(*)::BIGINT AS requests,
            COALESCE(SUM(usage.prompt_tokens), 0)::BIGINT AS prompt_tokens,
            COALESCE(SUM(usage.completion_tokens), 0)::BIGINT AS completion_tokens
        FROM public.usage, bounds
        WHERE usage.created_at >= end_at - $2::BIGINT * INTERVAL '1 second'
          AND usage.created_at < end_at
        GROUP BY 1
        ORDER BY 1
        LIMIT 256
        "#,
    )
    .bind(bucket_seconds)
    .bind(duration_seconds)
    .bind(end_epoch)
    .fetch_all(state.pool())
    .await
    .map_err(|error| OperationsError::internal("load network series", error))?;
    let time_series = rows
        .into_iter()
        .map(|row| {
            json!({
                "timestamp": row.get::<String, _>("timestamp"),
                "requests": row.get::<i64, _>("requests"),
                "prompt_tokens": row.get::<i64, _>("prompt_tokens"),
                "completion_tokens": row.get::<i64, _>("completion_tokens"),
            })
        })
        .collect::<Vec<_>>();
    Ok(Json(json!({
        "window": window,
        "bucket_seconds": bucket_seconds,
        "start_at": start_at,
        "end_at": end_at,
        "time_series": time_series,
        "updated_at": database_now(state.pool()).await?,
    })))
}

pub(super) async fn version(
    State(state): State<Arc<OperationsState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, OperationsError> {
    require_public(&state.auth, &headers)?;
    let release = sqlx::query(
        r#"
        SELECT version, platform, backend, binary_hash, bundle_hash, metallib_hash,
               python_hash, runtime_hash, template_hashes, grpc_binary_hash,
               url, changelog
        FROM public.releases
        WHERE platform='macos-arm64' AND active
        ORDER BY created_at DESC LIMIT 1
        "#,
    )
    .fetch_optional(state.pool())
    .await
    .map_err(|error| OperationsError::internal("load current version", error))?;
    if let Some(row) = release {
        return Ok(Json(release_json(&row)));
    }
    let fallback = state
        .settings
        .release_cdn_url
        .join(&format!(
            "releases/v{}/darkbloom-bundle-macos-arm64.tar.gz",
            state.settings.provider_version
        ))
        .map_err(|error| OperationsError::internal("construct fallback release URL", error))?;
    Ok(Json(json!({
        "version": state.settings.provider_version.as_ref(),
        "platform": "macos-arm64",
        "download_url": fallback.as_str(),
    })))
}

pub(super) fn release_json(row: &sqlx::postgres::PgRow) -> Value {
    json!({
        "version": row.get::<String, _>("version"),
        "platform": row.get::<String, _>("platform"),
        "backend": row.get::<String, _>("backend"),
        "binary_hash": row.get::<String, _>("binary_hash"),
        "bundle_hash": row.get::<String, _>("bundle_hash"),
        "metallib_hash": row.get::<String, _>("metallib_hash"),
        "python_hash": row.get::<String, _>("python_hash"),
        "runtime_hash": row.get::<String, _>("runtime_hash"),
        "template_hashes": row.get::<String, _>("template_hashes"),
        "grpc_binary_hash": row.get::<String, _>("grpc_binary_hash"),
        "url": row.get::<String, _>("url"),
        "changelog": row.get::<String, _>("changelog"),
    })
}

async fn persisted_provider_data(
    pool: &sqlx::PgPool,
    provider_ids: &[String],
) -> Result<BTreeMap<String, Value>, OperationsError> {
    if provider_ids.is_empty() {
        return Ok(BTreeMap::new());
    }
    let rows = sqlx::query(
        r#"
        SELECT id, hardware, trust_level, attested, mda_verified, runtime_verified, version
        FROM public.providers WHERE id = ANY($1)
        "#,
    )
    .bind(provider_ids)
    .fetch_all(pool)
    .await
    .map_err(|error| OperationsError::internal("load live provider details", error))?;
    Ok(rows
        .into_iter()
        .map(|row| {
            let id = row.get::<String, _>("id");
            let value = json!({
                "hardware": row.get::<SqlJson<Value>, _>("hardware").0,
                "trust_level": row.get::<String, _>("trust_level"),
                "attested": row.get::<bool, _>("attested"),
                "mda_verified": row.get::<bool, _>("mda_verified"),
                "runtime_verified": row.get::<bool, _>("runtime_verified"),
                "version": row.get::<String, _>("version"),
            });
            (id, value)
        })
        .collect())
}

fn parse_window(window: Option<&str>) -> Result<(&str, Option<i64>), OperationsError> {
    match window.unwrap_or("all") {
        "" | "all" | "lifetime" => Ok(("all", None)),
        "24h" | "1d" => Ok(("24h", Some(24 * 60 * 60))),
        "7d" => Ok(("7d", Some(7 * 24 * 60 * 60))),
        "30d" => Ok(("30d", Some(30 * 24 * 60 * 60))),
        _ => Err(OperationsError::bad_request(
            "window must be one of: 24h, 7d, 30d, all",
        )),
    }
}

fn parse_network_series_window(
    window: Option<&str>,
) -> Result<(&'static str, i64, i64), OperationsError> {
    match window.unwrap_or("30m") {
        "" | "30m" => Ok(("30m", 30 * 60, 60)),
        "24h" | "1d" => Ok(("24h", 24 * 60 * 60, 30 * 60)),
        "7d" => Ok(("7d", 7 * 24 * 60 * 60, 4 * 60 * 60)),
        "30d" => Ok(("30d", 30 * 24 * 60 * 60, 12 * 60 * 60)),
        _ => Err(OperationsError::bad_request(
            "window must be one of: 30m, 24h, 7d, 30d",
        )),
    }
}

fn pseudonym(account_id: &str) -> String {
    if account_id.is_empty() {
        return "anon".to_owned();
    }
    let digest = Sha256::digest(account_id.as_bytes());
    format!(
        "node-{}",
        digest[..6]
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>()
    )
}

async fn database_now(pool: &sqlx::PgPool) -> Result<String, OperationsError> {
    sqlx::query_scalar(
        r#"SELECT to_char(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')"#,
    )
    .fetch_one(pool)
    .await
    .map_err(|error| OperationsError::internal("read database time", error))
}

#[cfg(test)]
mod tests {
    use super::parse_network_series_window;

    #[test]
    fn network_series_windows_match_the_go_contract() {
        assert_eq!(
            parse_network_series_window(None).expect("default"),
            ("30m", 1_800, 60)
        );
        assert_eq!(
            parse_network_series_window(Some("1d")).expect("day alias"),
            ("24h", 86_400, 1_800)
        );
        assert_eq!(
            parse_network_series_window(Some("7d")).expect("week"),
            ("7d", 604_800, 14_400)
        );
        assert_eq!(
            parse_network_series_window(Some("30d")).expect("month"),
            ("30d", 2_592_000, 43_200)
        );
        assert!(parse_network_series_window(Some("31d")).is_err());
    }
}
