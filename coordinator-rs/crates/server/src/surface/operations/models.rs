use std::{
    collections::{BTreeMap, BTreeSet},
    sync::Arc,
};

use axum::{
    Json,
    body::{Body, to_bytes},
    extract::{Path, Query, Request, State},
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Response},
};
use futures_util::StreamExt as _;
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use sqlx::{PgPool, Row, types::Json as SqlJson};

use super::{
    OperationsState,
    auth::{require_public, require_publishing},
    error::OperationsError,
};

const MAX_MODEL_BODY: usize = 256 * 1024;
const MAX_MANIFEST_BODY: usize = 10 * 1024 * 1024;
const MAX_ALIAS_ID: usize = 128;
const MAX_RETIRED_BUILDS: usize = 16;

#[derive(Clone, Debug, Serialize)]
struct RegistryModel {
    id: String,
    display_name: String,
    family: String,
    architecture: String,
    quantization: String,
    max_context_length: i32,
    max_output_length: i32,
    min_ram_gb: i32,
    capabilities: Vec<String>,
    status: String,
    description: String,
    runtime_parameters: Value,
    metadata: Value,
    created: i64,
    updated_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    active_version: Option<ModelVersion>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    files: Vec<ModelFile>,
}

#[derive(Clone, Debug, Serialize)]
struct ModelVersion {
    id: i64,
    model_id: String,
    version: String,
    r2_prefix: String,
    aggregate_sha256: String,
    total_size_bytes: i64,
    file_count: i32,
    status: String,
    uploaded_by: String,
    uploaded_at: String,
    promoted_at: Option<String>,
    metadata: Value,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct ModelFile {
    #[serde(default, skip_serializing_if = "is_zero_i64")]
    id: i64,
    #[serde(default, skip_serializing_if = "is_zero_i64")]
    model_version_id: i64,
    path: String,
    size_bytes: i64,
    sha256: String,
    role: String,
}

#[derive(Clone, Debug, Serialize)]
struct ModelAlias {
    alias_id: String,
    display_name: String,
    desired_build: String,
    previous_build: String,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    retired_builds: Vec<String>,
    active: bool,
    created_at: String,
    updated_at: String,
}

#[derive(Clone, Copy, Debug, Default, Serialize)]
struct LiveCapacity {
    routable_providers: usize,
    warm_providers: usize,
    available_concurrency: u64,
    available_tokens: u64,
    can_accept: bool,
}

#[derive(Debug, Deserialize)]
pub(super) struct ListQuery {
    include_builds: Option<String>,
    include_aliases: Option<String>,
    #[serde(rename = "type")]
    model_type: Option<String>,
}

pub(super) async fn list_models(
    State(state): State<Arc<OperationsState>>,
    headers: HeaderMap,
    Query(query): Query<ListQuery>,
) -> Result<Json<Value>, OperationsError> {
    require_public(&state.auth, &headers)?;
    let models = active_models(state.pool()).await?;
    let aliases = aliases(state.pool()).await?;
    let capacity = capacity_by_model(&state);
    let data = public_model_entries(
        &models,
        &aliases,
        &capacity,
        query.include_builds.as_deref() == Some("1"),
    );
    Ok(Json(json!({"object": "list", "data": data})))
}

pub(super) async fn list_openrouter(
    State(state): State<Arc<OperationsState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, OperationsError> {
    require_public(&state.auth, &headers)?;
    let models = active_models(state.pool()).await?;
    let aliases = aliases(state.pool()).await?;
    let prices = platform_prices(state.pool()).await?;
    let entries = public_model_entries(&models, &aliases, &capacity_by_model(&state), false);
    let mut data = Vec::with_capacity(entries.len());
    for entry in entries {
        let id = entry.get("id").and_then(Value::as_str).unwrap_or_default();
        let concrete = entry
            .get("hugging_face_id")
            .and_then(Value::as_str)
            .unwrap_or(id);
        let model = models.iter().find(|model| model.id == concrete);
        let (input, output) = prices.get(concrete).copied().unwrap_or_default();
        let metadata = model.map(|model| &model.metadata);
        data.push(json!({
            "id": id,
            "hugging_face_id": concrete,
            "name": entry.get("name").cloned().unwrap_or_else(|| Value::String(id.to_owned())),
            "context_length": model.map_or(0, |model| model.max_context_length),
            "max_completion_tokens": model.map_or(0, |model| model.max_output_length),
            "pricing": {
                "prompt": per_token_price(input),
                "completion": per_token_price(output),
            },
            "input_modalities": entry.get("input_modalities").cloned().unwrap_or_else(|| json!(["text"])),
            "output_modalities": ["text"],
            "supported_features": model.map_or_else(Vec::new, |model| supported_features(&model.capabilities)),
            "supported_sampling_parameters": [
                "temperature", "top_p", "top_k", "max_tokens", "stop",
                "frequency_penalty", "presence_penalty", "seed", "response_format", "tools"
            ],
            "is_ready": metadata
                .and_then(|value| value.get("openrouter_is_ready"))
                .and_then(Value::as_bool)
                .unwrap_or(true),
            "openrouter": {
                "slug": metadata
                    .and_then(|value| value.get("openrouter_slug"))
                    .and_then(Value::as_str)
                    .unwrap_or(id)
            }
        }));
    }
    Ok(Json(json!({"data": data})))
}

pub(super) async fn model_detail(
    State(state): State<Arc<OperationsState>>,
    headers: HeaderMap,
    Path(model_id): Path<String>,
) -> Result<Json<Value>, OperationsError> {
    require_public(&state.auth, &headers)?;
    let models = active_models(state.pool()).await?;
    let aliases = aliases(state.pool()).await?;
    let entries = public_model_entries(&models, &aliases, &capacity_by_model(&state), true);
    entries
        .into_iter()
        .find(|entry| entry.get("id").and_then(Value::as_str) == Some(model_id.as_str()))
        .map(Json)
        .ok_or_else(|| OperationsError::not_found(format!("model {model_id:?} not found")))
}

pub(super) async fn model_capacity(
    State(state): State<Arc<OperationsState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, OperationsError> {
    require_public(&state.auth, &headers)?;
    if state.is_draining() {
        return Ok(Json(json!({"models": [], "draining": true})));
    }
    let models = capacity_by_model(&state)
        .into_iter()
        .map(|(model_id, capacity)| {
            json!({
                "model_id": model_id,
                "routable_providers": capacity.routable_providers,
                "warm_providers": capacity.warm_providers,
                "available_concurrency": capacity.available_concurrency,
                "available_tokens": capacity.available_tokens,
                "can_accept": capacity.can_accept,
            })
        })
        .collect::<Vec<_>>();
    Ok(Json(json!({"models": models})))
}

pub(super) async fn catalog(
    State(state): State<Arc<OperationsState>>,
    headers: HeaderMap,
    Query(query): Query<ListQuery>,
) -> Result<Json<Value>, OperationsError> {
    require_public(&state.auth, &headers)?;
    if let Some(kind) = query.model_type.as_deref()
        && kind != "text"
    {
        return Ok(Json(json!({"models": [], "aliases": []})));
    }
    let models = active_models(state.pool()).await?;
    let model_values = models.iter().map(catalog_value).collect::<Vec<_>>();
    let aliases = if query.include_aliases.as_deref() == Some("true") {
        Value::Array(catalog_alias_values(&models, &aliases(state.pool()).await?))
    } else {
        json!([])
    };
    Ok(Json(json!({"models": model_values, "aliases": aliases})))
}

pub(super) async fn catalog_item(
    State(state): State<Arc<OperationsState>>,
    headers: HeaderMap,
    Path(model_id): Path<String>,
) -> Result<Json<Value>, OperationsError> {
    require_public(&state.auth, &headers)?;
    let model = model_by_id(state.pool(), &model_id)
        .await?
        .ok_or_else(|| OperationsError::not_found("model not found"))?;
    Ok(Json(catalog_value(&model)))
}

pub(super) async fn manifest(
    State(state): State<Arc<OperationsState>>,
    headers: HeaderMap,
    Path(model_id): Path<String>,
) -> Result<Json<Value>, OperationsError> {
    require_public(&state.auth, &headers)?;
    let model = model_by_id(state.pool(), &model_id)
        .await?
        .filter(|model| model.active_version.is_some())
        .ok_or_else(|| OperationsError::not_found("model manifest not found"))?;
    let version = model
        .active_version
        .as_ref()
        .expect("presence checked above");
    Ok(Json(json!({
        "schema_version": 1,
        "model_id": model.id,
        "version": version.version,
        "r2_prefix": version.r2_prefix,
        "aggregate_sha256": version.aggregate_sha256,
        "total_size_bytes": version.total_size_bytes,
        "file_count": version.file_count,
        "files": model.files,
        "created_at": version.uploaded_at,
    })))
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RegisterModelRequest {
    model_id: String,
    version: String,
    #[serde(default)]
    display_name: String,
    #[serde(default)]
    family: String,
    #[serde(default)]
    architecture: String,
    quantization: String,
    max_context_length: i32,
    max_output_length: i32,
    min_ram_gb: i32,
    #[serde(default)]
    capabilities: Vec<String>,
    #[serde(default)]
    description: String,
    #[serde(default = "empty_object")]
    runtime_parameters: Value,
    #[serde(default = "empty_object")]
    metadata: Value,
    #[serde(default)]
    promote: bool,
    input_price: i64,
    output_price: i64,
}

#[derive(Debug, Deserialize)]
struct PublishedManifest {
    schema_version: i32,
    model_id: String,
    version: String,
    r2_prefix: String,
    aggregate_sha256: String,
    total_size_bytes: i64,
    file_count: i32,
    files: Vec<ModelFile>,
}

pub(super) async fn register_model(
    State(state): State<Arc<OperationsState>>,
    request: Request,
) -> Result<Json<Value>, OperationsError> {
    let actor = require_publishing(&state.auth, &state.database, request.headers()).await?;
    let request: RegisterModelRequest = json_request(request, MAX_MODEL_BODY).await?;
    validate_registration(&request)?;
    if alias_by_id(state.pool(), &request.model_id)
        .await?
        .is_some()
    {
        return Err(OperationsError::conflict(
            "model_alias_collision",
            "model_id collides with an existing public alias",
        ));
    }
    let prefix = model_r2_prefix(&request.model_id, &request.version);
    let published = fetch_manifest(&state, &prefix).await?;
    validate_manifest(&published, &request.model_id, &request.version, &prefix)?;
    verify_manifest_files(&state, &published).await?;

    let mut transaction = state
        .database
        .begin_owned()
        .await
        .map_err(|error| OperationsError::internal("begin model registration", error))?;
    let display_name = if request.display_name.is_empty() {
        &request.model_id
    } else {
        &request.display_name
    };
    sqlx::query(
        r#"
        INSERT INTO public.model_registry (
            id, display_name, family, architecture, quantization,
            max_context_length, max_output_length, min_ram_gb, capabilities,
            status, description, runtime_parameters, metadata
        ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,'beta',$10,$11,$12)
        ON CONFLICT (id) DO UPDATE SET
            display_name=EXCLUDED.display_name, family=EXCLUDED.family,
            architecture=EXCLUDED.architecture, quantization=EXCLUDED.quantization,
            max_context_length=EXCLUDED.max_context_length,
            max_output_length=EXCLUDED.max_output_length,
            min_ram_gb=EXCLUDED.min_ram_gb, capabilities=EXCLUDED.capabilities,
            description=EXCLUDED.description,
            runtime_parameters=EXCLUDED.runtime_parameters,
            metadata=EXCLUDED.metadata, updated_at=NOW()
        "#,
    )
    .bind(&request.model_id)
    .bind(display_name)
    .bind(&request.family)
    .bind(&request.architecture)
    .bind(&request.quantization)
    .bind(request.max_context_length)
    .bind(request.max_output_length)
    .bind(request.min_ram_gb)
    .bind(normalize_capabilities(request.capabilities))
    .bind(&request.description)
    .bind(SqlJson(request.runtime_parameters))
    .bind(SqlJson(request.metadata.clone()))
    .execute(transaction.connection())
    .await
    .map_err(|error| OperationsError::internal("upsert model registry", error))?;
    let version_id: i64 = sqlx::query_scalar(
        r#"
        INSERT INTO public.model_versions (
            model_id, version, r2_prefix, aggregate_sha256, total_size_bytes,
            file_count, status, uploaded_by, metadata
        ) VALUES ($1,$2,$3,$4,$5,$6,'ready',$7,$8)
        ON CONFLICT (model_id, version) DO UPDATE SET
            r2_prefix=EXCLUDED.r2_prefix,
            aggregate_sha256=EXCLUDED.aggregate_sha256,
            total_size_bytes=EXCLUDED.total_size_bytes,
            file_count=EXCLUDED.file_count,
            status='ready', uploaded_by=EXCLUDED.uploaded_by,
            metadata=EXCLUDED.metadata
        RETURNING id
        "#,
    )
    .bind(&request.model_id)
    .bind(&request.version)
    .bind(&prefix)
    .bind(&published.aggregate_sha256)
    .bind(published.total_size_bytes)
    .bind(published.file_count)
    .bind(&actor.name)
    .bind(SqlJson(request.metadata))
    .fetch_one(transaction.connection())
    .await
    .map_err(|error| OperationsError::internal("upsert model version", error))?;
    sqlx::query("DELETE FROM public.model_version_files WHERE model_version_id=$1")
        .bind(version_id)
        .execute(transaction.connection())
        .await
        .map_err(|error| OperationsError::internal("replace model files", error))?;
    for file in &published.files {
        sqlx::query(
            r#"
            INSERT INTO public.model_version_files
                (model_version_id, path, size_bytes, sha256, role)
            VALUES ($1,$2,$3,$4,$5)
            "#,
        )
        .bind(version_id)
        .bind(&file.path)
        .bind(file.size_bytes)
        .bind(&file.sha256)
        .bind(&file.role)
        .execute(transaction.connection())
        .await
        .map_err(|error| OperationsError::internal("insert model file", error))?;
    }
    sqlx::query(
        r#"
        INSERT INTO public.model_prices
            (account_id, model, input_price, output_price, updated_at)
        VALUES ('platform',$1,$2,$3,NOW())
        ON CONFLICT (account_id, model) DO UPDATE SET
            input_price=EXCLUDED.input_price,
            output_price=EXCLUDED.output_price,
            updated_at=NOW()
        "#,
    )
    .bind(&request.model_id)
    .bind(request.input_price)
    .bind(request.output_price)
    .execute(transaction.connection())
    .await
    .map_err(|error| OperationsError::internal("set model price", error))?;
    if request.promote {
        promote_version(
            transaction.connection(),
            &request.model_id,
            &request.version,
        )
        .await?;
    }
    transaction
        .commit()
        .await
        .map_err(|error| OperationsError::internal("commit model registration", error))?;
    state.mark_mutation();
    state.metrics.increment("models_registered");
    Ok(Json(json!({
        "status": "registered",
        "model": request.model_id,
        "version": request.version,
        "files": published.files.len(),
        "input_price": request.input_price,
        "output_price": request.output_price,
        "publishing_key_id": actor.id,
    })))
}

pub(super) async fn list_aliases(
    State(state): State<Arc<OperationsState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, OperationsError> {
    let _actor = require_publishing(&state.auth, &state.database, &headers).await?;
    Ok(Json(json!({"aliases": aliases(state.pool()).await?})))
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct AliasRequest {
    alias_id: String,
    #[serde(default)]
    display_name: String,
    desired_build: String,
    #[serde(default)]
    previous_build: String,
    active: Option<bool>,
    #[serde(default)]
    takeover: bool,
}

pub(super) async fn upsert_alias(
    State(state): State<Arc<OperationsState>>,
    request: Request,
) -> Result<Json<Value>, OperationsError> {
    let _actor = require_publishing(&state.auth, &state.database, request.headers()).await?;
    let mut request: AliasRequest = json_request(request, MAX_MODEL_BODY).await?;
    request.alias_id = request.alias_id.trim().to_owned();
    request.desired_build = request.desired_build.trim().to_owned();
    request.previous_build = request.previous_build.trim().to_owned();
    validate_alias_request(state.pool(), &request).await?;
    let prior = alias_by_id(state.pool(), &request.alias_id).await?;
    let retired = retired_after_upsert(
        prior.as_ref(),
        &request.desired_build,
        &request.previous_build,
    );
    let mut transaction = state
        .database
        .begin_owned()
        .await
        .map_err(|error| OperationsError::internal("begin alias upsert", error))?;
    sqlx::query(
        r#"
        INSERT INTO public.model_aliases (
            alias_id, display_name, desired_build, previous_build,
            retired_builds, active
        ) VALUES ($1,$2,$3,$4,$5,$6)
        ON CONFLICT (alias_id) DO UPDATE SET
            display_name=EXCLUDED.display_name,
            desired_build=EXCLUDED.desired_build,
            previous_build=EXCLUDED.previous_build,
            retired_builds=EXCLUDED.retired_builds,
            active=EXCLUDED.active,
            updated_at=NOW()
        "#,
    )
    .bind(&request.alias_id)
    .bind(&request.display_name)
    .bind(&request.desired_build)
    .bind(&request.previous_build)
    .bind(SqlJson(retired))
    .bind(request.active.unwrap_or(true))
    .execute(transaction.connection())
    .await
    .map_err(|error| OperationsError::internal("upsert model alias", error))?;
    transaction
        .commit()
        .await
        .map_err(|error| OperationsError::internal("commit alias upsert", error))?;
    state.mark_mutation();
    let alias = alias_by_id(state.pool(), &request.alias_id)
        .await?
        .ok_or_else(|| OperationsError::internal("reload model alias", "missing row"))?;
    Ok(Json(json!({"status": "ok", "alias": alias})))
}

pub(super) async fn delete_alias(
    State(state): State<Arc<OperationsState>>,
    headers: HeaderMap,
    Path(alias_id): Path<String>,
) -> Result<Json<Value>, OperationsError> {
    let _actor = require_publishing(&state.auth, &state.database, &headers).await?;
    if alias_id.is_empty() {
        return Err(OperationsError::bad_request("alias id is required"));
    }
    let mut transaction = state
        .database
        .begin_owned()
        .await
        .map_err(|error| OperationsError::internal("begin alias delete", error))?;
    let result = sqlx::query("DELETE FROM public.model_aliases WHERE alias_id=$1")
        .bind(&alias_id)
        .execute(transaction.connection())
        .await
        .map_err(|error| OperationsError::internal("delete model alias", error))?;
    if result.rows_affected() == 0 {
        return Err(OperationsError::not_found("model alias not found"));
    }
    transaction
        .commit()
        .await
        .map_err(|error| OperationsError::internal("commit alias delete", error))?;
    state.mark_mutation();
    Ok(Json(json!({"status": "deleted", "alias_id": alias_id})))
}

pub(super) async fn admin_model_action(
    State(state): State<Arc<OperationsState>>,
    Path(action_path): Path<String>,
    request: Request,
) -> Result<Json<Value>, OperationsError> {
    let _actor = require_publishing(&state.auth, &state.database, request.headers()).await?;
    let (model_id, action) = action_path
        .rsplit_once('/')
        .ok_or_else(|| OperationsError::not_found("model action not found"))?;
    if !valid_registry_id(model_id, true) {
        return Err(OperationsError::not_found("model action not found"));
    }
    let body = to_bytes(request.into_body(), MAX_MODEL_BODY)
        .await
        .map_err(|_| OperationsError::payload_too_large("model action body too large"))?;
    let mut transaction = state
        .database
        .begin_owned()
        .await
        .map_err(|error| OperationsError::internal("begin model action", error))?;
    let response = match action {
        "promote" => {
            #[derive(Deserialize)]
            struct Input {
                version: String,
            }
            let input: Input = parse_json(&body)?;
            if !valid_registry_id(&input.version, false) {
                return Err(OperationsError::bad_request("valid version is required"));
            }
            promote_version(transaction.connection(), model_id, &input.version).await?;
            json!({"status": "promoted", "model_id": model_id, "version": input.version})
        }
        "status" => {
            #[derive(Deserialize)]
            struct Input {
                status: String,
            }
            let input: Input = parse_json(&body)?;
            if !matches!(
                input.status.as_str(),
                "beta" | "active" | "deprecated" | "retired"
            ) {
                return Err(OperationsError::bad_request(
                    "status must be beta, active, deprecated, or retired",
                ));
            }
            update_model_field(
                transaction.connection(),
                model_id,
                "status",
                Value::String(input.status.clone()),
            )
            .await?;
            json!({"status": "updated", "model_id": model_id, "model_status": input.status})
        }
        "runtime-parameters" => {
            #[derive(Deserialize)]
            struct Input {
                runtime_parameters: Map<String, Value>,
            }
            let input: Input = parse_json(&body)?;
            let merged = merge_json_field(
                transaction.connection(),
                model_id,
                "runtime_parameters",
                input.runtime_parameters,
            )
            .await?;
            json!({"status": "updated", "model_id": model_id, "runtime_parameters": merged})
        }
        "capabilities" => {
            #[derive(Deserialize)]
            struct Input {
                capabilities: Vec<String>,
            }
            let input: Input = parse_json(&body)?;
            let capabilities = normalize_capabilities(input.capabilities);
            let result = sqlx::query(
                "UPDATE public.model_registry SET capabilities=$2, updated_at=NOW() WHERE id=$1",
            )
            .bind(model_id)
            .bind(&capabilities)
            .execute(transaction.connection())
            .await
            .map_err(|error| OperationsError::internal("update model capabilities", error))?;
            require_affected(result.rows_affected(), "model")?;
            json!({"status": "updated", "model_id": model_id, "capabilities": capabilities})
        }
        "deprecation" => {
            let input: Value = if body.is_empty() {
                json!({})
            } else {
                parse_json(&body)?
            };
            let date = input
                .get("deprecation_date")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .trim();
            if !date.is_empty() && !valid_iso_date(date) {
                return Err(OperationsError::bad_request(
                    "deprecation_date must be an ISO 8601 date (YYYY-MM-DD)",
                ));
            }
            let metadata = update_metadata_string(
                transaction.connection(),
                model_id,
                "deprecation_date",
                date,
            )
            .await?;
            json!({
                "status": "updated",
                "model_id": model_id,
                "deprecation_date": metadata.get("deprecation_date"),
                "note": if date.is_empty() {
                    Some("deprecation date cleared")
                } else {
                    None
                },
            })
        }
        "openrouter-slug" => {
            let input: Value = if body.is_empty() {
                json!({})
            } else {
                parse_json(&body)?
            };
            let slug = input
                .get("slug")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .trim();
            let metadata =
                update_metadata_string(transaction.connection(), model_id, "openrouter_slug", slug)
                    .await?;
            json!({
                "status": "updated",
                "model_id": model_id,
                "openrouter_slug": metadata.get("openrouter_slug"),
                "note": if slug.is_empty() {
                    Some("openrouter slug cleared — feed falls back to the model id")
                } else {
                    None
                },
            })
        }
        _ => return Err(OperationsError::not_found("model action not found")),
    };
    transaction
        .commit()
        .await
        .map_err(|error| OperationsError::internal("commit model action", error))?;
    state.mark_mutation();
    Ok(Json(response))
}

async fn active_models(pool: &PgPool) -> Result<Vec<RegistryModel>, OperationsError> {
    load_models(pool, None, true).await
}

async fn model_by_id(
    pool: &PgPool,
    model_id: &str,
) -> Result<Option<RegistryModel>, OperationsError> {
    Ok(load_models(pool, Some(model_id), false).await?.pop())
}

async fn load_models(
    pool: &PgPool,
    model_id: Option<&str>,
    active_only: bool,
) -> Result<Vec<RegistryModel>, OperationsError> {
    let rows = sqlx::query(
        r#"
        SELECT
            mr.id, mr.display_name, mr.family, mr.architecture, mr.quantization,
            mr.max_context_length, mr.max_output_length, mr.min_ram_gb,
            mr.capabilities, mr.status, mr.description,
            mr.runtime_parameters, mr.metadata,
            EXTRACT(EPOCH FROM mr.created_at)::BIGINT AS created,
            to_char(mr.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS updated_at,
            mv.id AS version_id, mv.model_id AS version_model_id,
            mv.version, mv.r2_prefix, mv.aggregate_sha256,
            mv.total_size_bytes, mv.file_count, mv.status AS version_status,
            mv.uploaded_by,
            to_char(mv.uploaded_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS uploaded_at,
            to_char(mv.promoted_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS promoted_at,
            mv.metadata AS version_metadata
        FROM public.model_registry mr
        LEFT JOIN public.model_active_versions mav ON mav.model_id=mr.id
        LEFT JOIN public.model_versions mv ON mv.id=mav.model_version_id
        WHERE ($1::TEXT IS NULL OR mr.id=$1)
          AND (NOT $2 OR (mr.status IN ('active','beta') AND mv.status='ready'))
        ORDER BY mr.min_ram_gb, mr.id
        "#,
    )
    .bind(model_id)
    .bind(active_only)
    .fetch_all(pool)
    .await
    .map_err(|error| OperationsError::internal("load model registry", error))?;
    let mut models = Vec::with_capacity(rows.len());
    for row in rows {
        let version_id: Option<i64> = row.get("version_id");
        let active_version = version_id.map(|id| ModelVersion {
            id,
            model_id: row.get("version_model_id"),
            version: row.get("version"),
            r2_prefix: row.get("r2_prefix"),
            aggregate_sha256: row.get("aggregate_sha256"),
            total_size_bytes: row.get("total_size_bytes"),
            file_count: row.get("file_count"),
            status: row.get("version_status"),
            uploaded_by: row.get("uploaded_by"),
            uploaded_at: row.get("uploaded_at"),
            promoted_at: row.get("promoted_at"),
            metadata: row
                .get::<Option<SqlJson<Value>>, _>("version_metadata")
                .map_or_else(empty_object, |value| value.0),
        });
        let files = if let Some(id) = version_id {
            load_files(pool, id).await?
        } else {
            Vec::new()
        };
        models.push(RegistryModel {
            id: row.get("id"),
            display_name: row.get("display_name"),
            family: row.get("family"),
            architecture: row.get("architecture"),
            quantization: row.get("quantization"),
            max_context_length: row.get("max_context_length"),
            max_output_length: row.get("max_output_length"),
            min_ram_gb: row.get("min_ram_gb"),
            capabilities: row.get("capabilities"),
            status: row.get("status"),
            description: row.get("description"),
            runtime_parameters: row.get::<SqlJson<Value>, _>("runtime_parameters").0,
            metadata: row.get::<SqlJson<Value>, _>("metadata").0,
            created: row.get("created"),
            updated_at: row.get("updated_at"),
            active_version,
            files,
        });
    }
    Ok(models)
}

async fn load_files(pool: &PgPool, version_id: i64) -> Result<Vec<ModelFile>, OperationsError> {
    let rows = sqlx::query(
        r#"
        SELECT id, model_version_id, path, size_bytes, sha256, role
        FROM public.model_version_files
        WHERE model_version_id=$1
        ORDER BY path
        "#,
    )
    .bind(version_id)
    .fetch_all(pool)
    .await
    .map_err(|error| OperationsError::internal("load model files", error))?;
    Ok(rows
        .into_iter()
        .map(|row| ModelFile {
            id: row.get("id"),
            model_version_id: row.get("model_version_id"),
            path: row.get("path"),
            size_bytes: row.get("size_bytes"),
            sha256: row.get("sha256"),
            role: row.get("role"),
        })
        .collect())
}

async fn aliases(pool: &PgPool) -> Result<Vec<ModelAlias>, OperationsError> {
    let rows = sqlx::query(
        r#"
        SELECT alias_id, display_name, desired_build, previous_build,
               retired_builds, active,
               to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS created_at,
               to_char(updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS updated_at
        FROM public.model_aliases ORDER BY alias_id
        "#,
    )
    .fetch_all(pool)
    .await
    .map_err(|error| OperationsError::internal("load model aliases", error))?;
    Ok(rows
        .into_iter()
        .map(|row| ModelAlias {
            alias_id: row.get("alias_id"),
            display_name: row.get("display_name"),
            desired_build: row.get("desired_build"),
            previous_build: row.get("previous_build"),
            retired_builds: row.get::<SqlJson<Vec<String>>, _>("retired_builds").0,
            active: row.get("active"),
            created_at: row.get("created_at"),
            updated_at: row.get("updated_at"),
        })
        .collect())
}

async fn alias_by_id(pool: &PgPool, alias_id: &str) -> Result<Option<ModelAlias>, OperationsError> {
    Ok(aliases(pool)
        .await?
        .into_iter()
        .find(|alias| alias.alias_id == alias_id))
}

fn capacity_by_model(state: &OperationsState) -> BTreeMap<String, LiveCapacity> {
    let mut capacity = BTreeMap::new();
    let Some(pilot) = state.pilot() else {
        return capacity;
    };
    for provider in pilot.fleet_snapshot().providers() {
        let snapshot = provider.provider();
        let model = snapshot.fence().model_id.as_str().to_owned();
        let entry = capacity.entry(model).or_insert_with(LiveCapacity::default);
        entry.warm_providers = entry.warm_providers.saturating_add(1);
        let counters = snapshot.capacity();
        let available_concurrency = counters
            .concurrency_limit()
            .saturating_sub(counters.concurrency_in_use());
        let available_tokens = counters
            .token_capacity()
            .get()
            .saturating_sub(counters.tokens_in_use().get());
        let routable = snapshot.health().admits_regular_traffic()
            && snapshot.traits().template_render_ok()
            && available_concurrency > 0
            && available_tokens > 0
            && provider.effective_writer_items() > 0
            && provider.effective_writer_bytes() > 0;
        if routable {
            entry.routable_providers = entry.routable_providers.saturating_add(1);
            entry.available_concurrency = entry
                .available_concurrency
                .saturating_add(u64::from(available_concurrency));
            entry.available_tokens = entry.available_tokens.saturating_add(available_tokens);
            entry.can_accept = true;
        }
    }
    capacity
}

fn public_model_entries(
    models: &[RegistryModel],
    aliases: &[ModelAlias],
    capacity: &BTreeMap<String, LiveCapacity>,
    include_builds: bool,
) -> Vec<Value> {
    let by_id = models
        .iter()
        .map(|model| (model.id.as_str(), model))
        .collect::<BTreeMap<_, _>>();
    let mut hidden = BTreeSet::new();
    let mut entries = Vec::new();
    for alias in aliases.iter().filter(|alias| alias.active) {
        hidden.insert(alias.desired_build.as_str());
        if !alias.previous_build.is_empty() {
            hidden.insert(alias.previous_build.as_str());
        }
        for retired in &alias.retired_builds {
            hidden.insert(retired.as_str());
        }
        let Some(primary) = by_id
            .get(alias.desired_build.as_str())
            .or_else(|| by_id.get(alias.previous_build.as_str()))
        else {
            continue;
        };
        let aggregated =
            aggregate_capacity(capacity, [&alias.desired_build, &alias.previous_build]);
        entries.push(model_entry(
            &alias.alias_id,
            if alias.display_name.is_empty() {
                &primary.display_name
            } else {
                &alias.display_name
            },
            primary,
            aggregated,
            true,
        ));
    }
    for model in models {
        if !include_builds && hidden.contains(model.id.as_str()) {
            continue;
        }
        entries.push(model_entry(
            &model.id,
            &model.display_name,
            model,
            capacity.get(&model.id).copied().unwrap_or_default(),
            false,
        ));
    }
    entries
}

fn aggregate_capacity<'a>(
    capacity: &BTreeMap<String, LiveCapacity>,
    models: impl IntoIterator<Item = &'a String>,
) -> LiveCapacity {
    models.into_iter().filter(|model| !model.is_empty()).fold(
        LiveCapacity::default(),
        |mut aggregate, model| {
            if let Some(current) = capacity.get(model) {
                aggregate.routable_providers = aggregate
                    .routable_providers
                    .saturating_add(current.routable_providers);
                aggregate.warm_providers = aggregate
                    .warm_providers
                    .saturating_add(current.warm_providers);
                aggregate.available_concurrency = aggregate
                    .available_concurrency
                    .saturating_add(current.available_concurrency);
                aggregate.available_tokens = aggregate
                    .available_tokens
                    .saturating_add(current.available_tokens);
                aggregate.can_accept |= current.can_accept;
            }
            aggregate
        },
    )
}

fn model_entry(
    id: &str,
    display_name: &str,
    model: &RegistryModel,
    capacity: LiveCapacity,
    alias: bool,
) -> Value {
    let input_modalities = if model
        .capabilities
        .iter()
        .any(|value| value == "vision" || value == "multimodal")
    {
        json!(["text", "image"])
    } else {
        json!(["text"])
    };
    json!({
        "id": id,
        "object": "model",
        "created": model.created,
        "owned_by": "darkbloom",
        "name": display_name,
        "hugging_face_id": model.id,
        "quantization": if alias { "" } else { &model.quantization },
        "context_length": model.max_context_length,
        "max_completion_tokens": model.max_output_length,
        "input_modalities": input_modalities,
        "output_modalities": ["text"],
        "supported_features": supported_features(&model.capabilities),
        "metadata": {
            "model_type": "text",
            "display_name": display_name,
            "quantization": if alias { "" } else { &model.quantization },
            "routable_providers": capacity.routable_providers,
            "warm_providers": capacity.warm_providers,
            "can_accept": capacity.can_accept,
        }
    })
}

fn catalog_value(model: &RegistryModel) -> Value {
    let version = model.active_version.as_ref();
    json!({
        "id": model.id,
        "display_name": model.display_name,
        "name": model.display_name,
        "hugging_face_id": model.id,
        "model_type": "text",
        "family": model.family,
        "architecture": model.architecture,
        "quantization": model.quantization,
        "max_context_length": model.max_context_length,
        "max_output_length": model.max_output_length,
        "min_ram_gb": model.min_ram_gb,
        "capabilities": model.capabilities,
        "description": model.description,
        "runtime_parameters": model.runtime_parameters,
        "metadata": model.metadata,
        "status": model.status,
        "active": matches!(model.status.as_str(), "active" | "beta") && version.is_some(),
        "weight_hash": version.map(|value| value.aggregate_sha256.as_str()).unwrap_or_default(),
        "version": version.map(|value| value.version.as_str()),
        "r2_prefix": version.map(|value| value.r2_prefix.as_str()),
        "aggregate_sha256": version.map(|value| value.aggregate_sha256.as_str()),
        "total_size_bytes": version.map(|value| value.total_size_bytes),
        "file_count": version.map(|value| value.file_count),
        "created": model.created,
        "input_modalities": if model.capabilities.iter().any(|value| value == "vision" || value == "multimodal") {
            json!(["text", "image"])
        } else {
            json!(["text"])
        },
        "output_modalities": ["text"],
        "supported_features": supported_features(&model.capabilities),
    })
}

fn catalog_alias_values(models: &[RegistryModel], aliases: &[ModelAlias]) -> Vec<Value> {
    let catalog_ids = models
        .iter()
        .map(|model| model.id.as_str())
        .collect::<BTreeSet<_>>();
    aliases
        .iter()
        .filter(|alias| alias.active && !alias.desired_build.is_empty())
        .filter_map(|alias| {
            let primary = if catalog_ids.contains(alias.desired_build.as_str()) {
                &alias.desired_build
            } else if catalog_ids.contains(alias.previous_build.as_str()) {
                &alias.previous_build
            } else {
                return None;
            };
            let mut value = json!({
                "id": alias.alias_id,
                "display_name": if alias.display_name.is_empty() {
                    &alias.alias_id
                } else {
                    &alias.display_name
                },
                "desired_build": alias.desired_build,
                "retired_builds": alias.retired_builds,
                "primary_build": primary,
            });
            if !alias.previous_build.is_empty() {
                value["previous_build"] = Value::String(alias.previous_build.clone());
            }
            Some(value)
        })
        .collect()
}

async fn platform_prices(pool: &PgPool) -> Result<BTreeMap<String, (i64, i64)>, OperationsError> {
    let rows = sqlx::query(
        "SELECT model, input_price, output_price FROM public.model_prices WHERE account_id='platform'",
    )
    .fetch_all(pool)
    .await
    .map_err(|error| OperationsError::internal("load model prices", error))?;
    Ok(rows
        .into_iter()
        .map(|row| {
            (
                row.get("model"),
                (row.get("input_price"), row.get("output_price")),
            )
        })
        .collect())
}

async fn validate_alias_request(
    pool: &PgPool,
    request: &AliasRequest,
) -> Result<(), OperationsError> {
    if request.alias_id.len() > MAX_ALIAS_ID || !valid_registry_id(&request.alias_id, false) {
        return Err(OperationsError::bad_request(
            "alias_id may only contain letters, digits, '.', '_' and '-' (max 128 chars)",
        ));
    }
    if request.desired_build.is_empty() {
        return Err(OperationsError::bad_request("desired_build is required"));
    }
    if request.desired_build == request.alias_id {
        return Err(OperationsError::bad_request(
            "desired_build cannot equal alias_id",
        ));
    }
    let collision = model_by_id(pool, &request.alias_id).await?.is_some();
    if collision && (!request.takeover || request.previous_build != request.alias_id) {
        return Err(OperationsError::conflict(
            "model_alias_collision",
            "takeover requires previous_build to equal the colliding alias_id",
        ));
    }
    if !collision && request.previous_build == request.alias_id {
        return Err(OperationsError::bad_request(
            "an alias cannot reference itself",
        ));
    }
    if !request.previous_build.is_empty() && request.previous_build == request.desired_build {
        return Err(OperationsError::bad_request(
            "previous_build must differ from desired_build",
        ));
    }
    for (name, model) in [
        ("desired_build", &request.desired_build),
        ("previous_build", &request.previous_build),
    ] {
        if !model.is_empty() && model_by_id(pool, model).await?.is_none() {
            return Err(OperationsError::bad_request(format!(
                "{name} {model} is not a registered model"
            )));
        }
    }
    Ok(())
}

fn retired_after_upsert(prior: Option<&ModelAlias>, desired: &str, previous: &str) -> Vec<String> {
    let Some(prior) = prior else {
        return Vec::new();
    };
    let mut retired = Vec::new();
    let mut seen = BTreeSet::new();
    for build in prior
        .retired_builds
        .iter()
        .chain([&prior.desired_build, &prior.previous_build])
    {
        if build.is_empty() || build == desired || build == previous || !seen.insert(build.clone())
        {
            continue;
        }
        retired.push(build.clone());
    }
    if retired.len() > MAX_RETIRED_BUILDS {
        retired.drain(..retired.len() - MAX_RETIRED_BUILDS);
    }
    retired
}

async fn fetch_manifest(
    state: &OperationsState,
    prefix: &str,
) -> Result<PublishedManifest, OperationsError> {
    let url = model_artifact_url(
        &state.settings.model_cdn_url,
        &format!("{prefix}/manifest.json"),
    );
    let response = state
        .http_client
        .get(url)
        .timeout(state.operation_timeout)
        .send()
        .await
        .map_err(|error| OperationsError::bad_request(format!("fetch manifest: {error}")))?;
    if !response.status().is_success() {
        return Err(OperationsError::bad_request(format!(
            "manifest GET returned {}",
            response.status()
        )));
    }
    let bytes = bounded_response(response, MAX_MANIFEST_BODY).await?;
    serde_json::from_slice(&bytes)
        .map_err(|error| OperationsError::bad_request(format!("invalid manifest: {error}")))
}

async fn verify_manifest_files(
    state: &OperationsState,
    manifest: &PublishedManifest,
) -> Result<(), OperationsError> {
    for file in &manifest.files {
        let url = model_artifact_url(
            &state.settings.model_cdn_url,
            &format!("{}/{}", manifest.r2_prefix, file.path),
        );
        let response = state
            .http_client
            .head(url)
            .timeout(state.operation_timeout)
            .send()
            .await
            .map_err(|error| {
                OperationsError::bad_request(format!("HEAD {}: {error}", file.path))
            })?;
        if !response.status().is_success() {
            return Err(OperationsError::bad_request(format!(
                "HEAD {} returned {}",
                file.path,
                response.status()
            )));
        }
        if let Some(value) = response.headers().get(header::CONTENT_LENGTH) {
            let length = value
                .to_str()
                .ok()
                .and_then(|value| value.parse::<u64>().ok())
                .ok_or_else(|| {
                    OperationsError::bad_request(format!(
                        "HEAD {} returned an invalid content length",
                        file.path
                    ))
                })?;
            if length != u64::try_from(file.size_bytes).unwrap_or(u64::MAX) {
                return Err(OperationsError::bad_request(format!(
                    "HEAD {} content length {} does not match manifest size {}",
                    file.path, length, file.size_bytes
                )));
            }
        }
    }
    Ok(())
}

fn model_artifact_url(origin: &url::Url, relative_path: &str) -> url::Url {
    let mut url = origin.clone();
    url.set_path(&format!("/{relative_path}"));
    url
}

fn validate_registration(request: &RegisterModelRequest) -> Result<(), OperationsError> {
    if !valid_registry_id(&request.model_id, true) {
        return Err(OperationsError::bad_request(
            "model_id contains invalid characters or path components",
        ));
    }
    if !valid_registry_id(&request.version, false) {
        return Err(OperationsError::bad_request(
            "version contains invalid characters or path components",
        ));
    }
    if request.quantization.trim().is_empty()
        || request.max_context_length <= 0
        || request.max_output_length <= 0
        || request.min_ram_gb <= 0
        || request.input_price <= 0
        || request.output_price <= 0
    {
        return Err(OperationsError::bad_request(
            "quantization, positive context/output/RAM limits, and positive prices are required",
        ));
    }
    if !request.runtime_parameters.is_object() || !request.metadata.is_object() {
        return Err(OperationsError::bad_request(
            "runtime_parameters and metadata must be objects",
        ));
    }
    Ok(())
}

fn validate_manifest(
    manifest: &PublishedManifest,
    model_id: &str,
    version: &str,
    prefix: &str,
) -> Result<(), OperationsError> {
    if manifest.schema_version != 1
        || manifest.model_id != model_id
        || manifest.version != version
        || manifest.r2_prefix != prefix
        || manifest.file_count != i32::try_from(manifest.files.len()).unwrap_or(i32::MAX)
        || manifest.files.is_empty()
        || manifest.total_size_bytes < 0
        || !is_sha256(&manifest.aggregate_sha256)
    {
        return Err(OperationsError::bad_request(
            "manifest fields do not match registration request",
        ));
    }
    let mut seen = BTreeSet::new();
    let mut total = 0_i64;
    let mut sorted = manifest.files.iter().collect::<Vec<_>>();
    sorted.sort_by(|left, right| left.path.cmp(&right.path));
    let mut aggregate = Sha256::new();
    for file in sorted {
        let key = file.path.to_ascii_lowercase();
        if !valid_manifest_path(&file.path)
            || file.size_bytes < 0
            || !is_sha256(&file.sha256)
            || !seen.insert(key)
        {
            return Err(OperationsError::bad_request(format!(
                "invalid manifest file {}",
                file.path
            )));
        }
        total = total
            .checked_add(file.size_bytes)
            .ok_or_else(|| OperationsError::bad_request("manifest size overflow"))?;
        aggregate.update(
            decode_sha256(&file.sha256)
                .ok_or_else(|| OperationsError::bad_request("invalid file SHA-256"))?,
        );
    }
    if total != manifest.total_size_bytes
        || encode_hex(&aggregate.finalize()) != manifest.aggregate_sha256
    {
        return Err(OperationsError::bad_request(
            "manifest aggregate does not match files",
        ));
    }
    Ok(())
}

async fn promote_version(
    connection: &mut sqlx::PgConnection,
    model_id: &str,
    version: &str,
) -> Result<(), OperationsError> {
    let version_id: Option<i64> = sqlx::query_scalar(
        "SELECT id FROM public.model_versions WHERE model_id=$1 AND version=$2 AND status='ready'",
    )
    .bind(model_id)
    .bind(version)
    .fetch_optional(&mut *connection)
    .await
    .map_err(|error| OperationsError::internal("find model version", error))?;
    let version_id =
        version_id.ok_or_else(|| OperationsError::not_found("model version not found"))?;
    sqlx::query(
        r#"
        INSERT INTO public.model_active_versions (model_id, model_version_id, activated_at)
        VALUES ($1,$2,NOW())
        ON CONFLICT (model_id) DO UPDATE SET
            model_version_id=EXCLUDED.model_version_id, activated_at=NOW()
        "#,
    )
    .bind(model_id)
    .bind(version_id)
    .execute(&mut *connection)
    .await
    .map_err(|error| OperationsError::internal("promote model version", error))?;
    sqlx::query("UPDATE public.model_versions SET promoted_at=NOW() WHERE id=$1")
        .bind(version_id)
        .execute(connection)
        .await
        .map_err(|error| OperationsError::internal("mark model promoted", error))?;
    Ok(())
}

async fn update_model_field(
    connection: &mut sqlx::PgConnection,
    model_id: &str,
    field: &str,
    value: Value,
) -> Result<(), OperationsError> {
    if field != "status" {
        return Err(OperationsError::internal(
            "update model field",
            "unsupported field",
        ));
    }
    let result =
        sqlx::query("UPDATE public.model_registry SET status=$2, updated_at=NOW() WHERE id=$1")
            .bind(model_id)
            .bind(value.as_str().unwrap_or_default())
            .execute(connection)
            .await
            .map_err(|error| OperationsError::internal("update model status", error))?;
    require_affected(result.rows_affected(), "model")
}

async fn merge_json_field(
    connection: &mut sqlx::PgConnection,
    model_id: &str,
    field: &str,
    patch: Map<String, Value>,
) -> Result<Value, OperationsError> {
    let query = match field {
        "runtime_parameters" => {
            "UPDATE public.model_registry SET runtime_parameters=runtime_parameters || $2, updated_at=NOW() WHERE id=$1 RETURNING runtime_parameters"
        }
        "metadata" => {
            "UPDATE public.model_registry SET metadata=metadata || $2, updated_at=NOW() WHERE id=$1 RETURNING metadata"
        }
        _ => {
            return Err(OperationsError::internal(
                "merge model field",
                "unsupported field",
            ));
        }
    };
    sqlx::query_scalar::<_, SqlJson<Value>>(query)
        .bind(model_id)
        .bind(SqlJson(Value::Object(patch)))
        .fetch_optional(connection)
        .await
        .map_err(|error| OperationsError::internal("merge model metadata", error))?
        .map(|value| value.0)
        .ok_or_else(|| OperationsError::not_found("model not found"))
}

async fn update_metadata_string(
    connection: &mut sqlx::PgConnection,
    model_id: &str,
    key: &'static str,
    value: &str,
) -> Result<Value, OperationsError> {
    let query = if value.is_empty() {
        "UPDATE public.model_registry SET metadata=metadata - $2, updated_at=NOW() WHERE id=$1 RETURNING metadata"
    } else {
        "UPDATE public.model_registry SET metadata=metadata || jsonb_build_object($2::TEXT, $3::TEXT), updated_at=NOW() WHERE id=$1 RETURNING metadata"
    };
    let mut query = sqlx::query_scalar::<_, SqlJson<Value>>(query)
        .bind(model_id)
        .bind(key);
    if !value.is_empty() {
        query = query.bind(value);
    }
    query
        .fetch_optional(connection)
        .await
        .map_err(|error| OperationsError::internal("update model metadata", error))?
        .map(|value| value.0)
        .ok_or_else(|| OperationsError::not_found("model not found"))
}

fn require_affected(affected: u64, resource: &str) -> Result<(), OperationsError> {
    if affected == 0 {
        Err(OperationsError::not_found(format!("{resource} not found")))
    } else {
        Ok(())
    }
}

fn supported_features(capabilities: &[String]) -> Vec<&'static str> {
    let mut supported = Vec::new();
    if capabilities.iter().any(|value| value == "tools") {
        supported.push("tools");
    }
    if capabilities
        .iter()
        .any(|value| value == "structured_output")
    {
        supported.push("structured_outputs");
    }
    if capabilities
        .iter()
        .any(|value| value == "vision" || value == "multimodal")
    {
        supported.push("vision");
    }
    supported
}

fn per_token_price(per_million: i64) -> String {
    format!("{:.12}", per_million as f64 / 1_000_000.0)
}

fn normalize_capabilities(capabilities: Vec<String>) -> Vec<String> {
    capabilities
        .into_iter()
        .map(|value| value.trim().to_ascii_lowercase())
        .filter(|value| !value.is_empty())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

pub(super) fn model_r2_prefix(model_id: &str, version: &str) -> String {
    let slug = model_id
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-') {
                character
            } else {
                '-'
            }
        })
        .collect::<String>()
        .trim_matches('-')
        .to_owned();
    let slug = if slug.is_empty() { "model" } else { &slug };
    let digest = Sha256::digest(model_id.as_bytes());
    format!("v2/{slug}--{}/{version}", &encode_hex(&digest)[..12])
}

fn valid_registry_id(value: &str, slash: bool) -> bool {
    !value.is_empty()
        && value.len() <= 256
        && !value.starts_with('/')
        && !value.contains("..")
        && value.chars().all(|character| {
            character.is_ascii_alphanumeric()
                || matches!(character, '.' | '_' | '-')
                || (slash && character == '/')
        })
}

fn valid_manifest_path(value: &str) -> bool {
    !value.is_empty()
        && !value.starts_with('/')
        && !value.contains('\\')
        && value
            .split('/')
            .all(|component| !component.is_empty() && component != "." && component != "..")
}

fn valid_iso_date(value: &str) -> bool {
    let bytes = value.as_bytes();
    if bytes.len() != 10 || bytes[4] != b'-' || bytes[7] != b'-' {
        return false;
    }
    let Some(year) = decimal(&bytes[0..4]) else {
        return false;
    };
    let Some(month) = decimal(&bytes[5..7]) else {
        return false;
    };
    let Some(day) = decimal(&bytes[8..10]) else {
        return false;
    };
    let maximum = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if year % 400 == 0 || (year % 4 == 0 && year % 100 != 0) => 29,
        2 => 28,
        _ => return false,
    };
    (1..=maximum).contains(&day)
}

fn decimal(bytes: &[u8]) -> Option<u32> {
    bytes.iter().try_fold(0_u32, |value, byte| {
        byte.is_ascii_digit()
            .then(|| value * 10 + u32::from(byte - b'0'))
    })
}

fn is_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn decode_sha256(value: &str) -> Option<[u8; 32]> {
    if !is_sha256(value) {
        return None;
    }
    let mut output = [0_u8; 32];
    for (index, chunk) in value.as_bytes().chunks_exact(2).enumerate() {
        let text = std::str::from_utf8(chunk).ok()?;
        output[index] = u8::from_str_radix(text, 16).ok()?;
    }
    Some(output)
}

fn encode_hex(value: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(value.len() * 2);
    for byte in value {
        output.push(HEX[usize::from(byte >> 4)] as char);
        output.push(HEX[usize::from(byte & 0x0f)] as char);
    }
    output
}

async fn bounded_response(
    response: reqwest::Response,
    limit: usize,
) -> Result<Vec<u8>, OperationsError> {
    if response
        .content_length()
        .is_some_and(|length| length > limit as u64)
    {
        return Err(OperationsError::payload_too_large(
            "upstream response exceeds size limit",
        ));
    }
    let mut bytes = Vec::new();
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk
            .map_err(|error| OperationsError::bad_request(format!("read upstream: {error}")))?;
        if bytes.len().saturating_add(chunk.len()) > limit {
            return Err(OperationsError::payload_too_large(
                "upstream response exceeds size limit",
            ));
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}

async fn json_request<T: DeserializeOwned>(
    request: Request,
    limit: usize,
) -> Result<T, OperationsError> {
    let bytes = to_bytes(request.into_body(), limit)
        .await
        .map_err(|_| OperationsError::payload_too_large("request body too large"))?;
    parse_json(&bytes)
}

fn parse_json<T: DeserializeOwned>(bytes: &[u8]) -> Result<T, OperationsError> {
    let mut deserializer = serde_json::Deserializer::from_slice(bytes);
    let parsed = T::deserialize(&mut deserializer)
        .map_err(|error| OperationsError::bad_request(format!("invalid JSON: {error}")))?;
    deserializer
        .end()
        .map_err(|error| OperationsError::bad_request(format!("invalid JSON: {error}")))?;
    Ok(parsed)
}

fn empty_object() -> Value {
    Value::Object(Map::new())
}

const fn is_zero_i64(value: &i64) -> bool {
    *value == 0
}

#[allow(dead_code)]
fn _response_type_anchor(_: Body) -> Response {
    StatusCode::OK.into_response()
}
