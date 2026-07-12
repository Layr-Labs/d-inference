use std::{
    collections::BTreeMap,
    fs,
    path::PathBuf,
    process::Command,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

use axum::{
    Json, Router,
    body::Body,
    extract::{Request as AxumRequest, State},
    http::{Method, Request, Response, StatusCode, header},
    routing::{get, post},
};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use darkbloom_coordinator_protocol::crypto::{BoxPayload, open_box};
use http_body_util::BodyExt as _;
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};
use sqlx::PgPool;
use tokio::{net::TcpListener, sync::mpsc, task::JoinHandle};
use tower::ServiceExt as _;
use url::Url;
use uuid::Uuid;

use crate::{database::Database, ownership::CoordinatorOwnership};

use super::{
    AdminOtpConfig, DatadogTelemetrySettings, ExactBearer, MdmAuth, OperationsAuth,
    OperationsBuildError, OperationsSettings, OperationsStateBuilder, PublicAuth, PublishingAuth,
    StateExportConfig, TelemetrySettings, models::model_r2_prefix, router, router_with_state,
};

#[allow(clippy::duplicate_mod)]
#[path = "../../../tests/postgres/support/database.rs"]
mod database;
#[allow(clippy::duplicate_mod)]
#[path = "../../../tests/postgres/support/schema_seed.rs"]
mod schema_seed;

use database::with_isolated_database;
use schema_seed::seed_service_schema;

const PUBLIC_TOKEN: &str = "operations-public";
const ADMIN_TOKEN: &str = "operations-admin";
const RELEASE_TOKEN: &str = "operations-release";
const PUBLISHING_TOKEN: &str = "operations-publishing";
const MDM_TOKEN: &str = "operations-mdm";
const PROCESS_PRIVATE: &str = "XasIfmJKikt54X+Lg4AO5m87sSkmGLb9HC+LJ/+I4Os=";
const PROCESS_PUBLIC: &str = "3p7bfXt9wbTTW2HC7OQ1Nz+DQ8hbeGdNrfx+FG+IK08=";

#[tokio::test]
async fn routes_enforce_auth_and_preserve_release_hash_and_404_semantics() {
    with_isolated_database(|url| async move {
        let test = TestDatabase::start(&url).await;
        let release = release_fixture();
        let artifacts = ArtifactServer::start(BTreeMap::from([(
            "/releases/v1.2.3/darkbloom-bundle-macos-arm64.tar.gz".to_owned(),
            release.bundle.clone(),
        )]))
        .await;
        let app = test.app(settings(&artifacts.base_url), 16, None);

        let install = call(&app, Method::GET, "/install.sh", None, None).await;
        assert_eq!(install.status(), StatusCode::OK);
        assert_eq!(
            install.headers().get(header::CACHE_CONTROL),
            Some(&header::HeaderValue::from_static("no-cache"))
        );
        let script = response_text(install).await;
        assert!(script.contains("COORD_URL:-https://coordinator.test"));
        assert!(!script.contains("__DARKBLOOM_COORD_URL__"));

        assert_eq!(
            call(&app, Method::GET, "/v1/models", None, None)
                .await
                .status(),
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            call(
                &app,
                Method::GET,
                "/v1/releases/latest",
                Some(PUBLIC_TOKEN),
                None,
            )
            .await
            .status(),
            StatusCode::NOT_FOUND
        );
        assert_eq!(
            call(
                &app,
                Method::POST,
                "/v1/releases",
                Some(ADMIN_TOKEN),
                Some(release.registration(&artifacts.base_url)),
            )
            .await
            .status(),
            StatusCode::UNAUTHORIZED,
            "admin credentials must not authorize the release endpoint"
        );

        let registered = call(
            &app,
            Method::POST,
            "/v1/releases",
            Some(RELEASE_TOKEN),
            Some(release.registration(&artifacts.base_url)),
        )
        .await;
        assert_eq!(registered.status(), StatusCode::OK);
        let latest = response_json(
            call(
                &app,
                Method::GET,
                "/v1/releases/latest",
                Some(PUBLIC_TOKEN),
                None,
            )
            .await,
        )
        .await;
        assert_eq!(latest["version"], "1.2.3");
        assert_eq!(latest["binary_hash"], release.binary_hash);
        assert_eq!(latest["bundle_hash"], release.bundle_hash);

        assert_eq!(
            call(&app, Method::GET, "/v1/admin/releases", None, None)
                .await
                .status(),
            StatusCode::FORBIDDEN
        );
        let deleted = call(
            &app,
            Method::DELETE,
            "/v1/admin/releases",
            Some(ADMIN_TOKEN),
            Some(json!({
                "version": "1.2.3",
                "platform": "macos-arm64",
                "force": true,
            })),
        )
        .await;
        assert_eq!(deleted.status(), StatusCode::OK);
        assert_eq!(
            call(
                &app,
                Method::GET,
                "/v1/releases/latest",
                Some(PUBLIC_TOKEN),
                None,
            )
            .await
            .status(),
            StatusCode::NOT_FOUND
        );

        artifacts.stop();
        test.stop().await;
    })
    .await;
}

#[tokio::test]
async fn model_registration_promotion_aliases_and_admin_lifecycle_are_db_backed() {
    with_isolated_database(|url| async move {
        let test = TestDatabase::start(&url).await;
        let model_id = "acme/private-chat";
        let version = "1.0.0";
        let prefix = model_r2_prefix(model_id, version);
        let weight = b"model-weight-bytes".to_vec();
        let weight_hash = digest_hex(&weight);
        let aggregate_hash = digest_hex(&Sha256::digest(&weight));
        let manifest = serde_json::to_vec(&json!({
            "schema_version": 1,
            "model_id": model_id,
            "version": version,
            "r2_prefix": prefix,
            "aggregate_sha256": aggregate_hash,
            "total_size_bytes": weight.len(),
            "file_count": 1,
            "files": [{
                "path": "weights/model.safetensors",
                "size_bytes": weight.len(),
                "sha256": weight_hash,
                "role": "weights",
            }],
        }))
        .expect("manifest");
        let artifacts = ArtifactServer::start(BTreeMap::from([
            (format!("/{prefix}/manifest.json"), manifest),
            (format!("/{prefix}/weights/model.safetensors"), weight),
        ]))
        .await;
        let app = test.app(settings(&artifacts.base_url), 16, None);

        assert_eq!(
            call(
                &app,
                Method::POST,
                "/v1/admin/models/register",
                None,
                Some(json!({})),
            )
            .await
            .status(),
            StatusCode::UNAUTHORIZED
        );
        let registration = call(
            &app,
            Method::POST,
            "/v1/admin/models/register",
            Some(PUBLISHING_TOKEN),
            Some(json!({
                "model_id": model_id,
                "version": version,
                "display_name": "Private Chat",
                "family": "private",
                "architecture": "transformer",
                "quantization": "4bit",
                "max_context_length": 32768,
                "max_output_length": 4096,
                "min_ram_gb": 16,
                "capabilities": ["tools", "tools"],
                "description": "DB-backed test model",
                "runtime_parameters": {"batch": 4},
                "metadata": {"openrouter_is_ready": true},
                "promote": true,
                "input_price": 10,
                "output_price": 20,
            })),
        )
        .await;
        assert_eq!(
            registration.status(),
            StatusCode::OK,
            "{}",
            response_text(registration).await
        );

        let detail = response_json(
            call(
                &app,
                Method::GET,
                "/v1/models/acme/private-chat",
                Some(PUBLIC_TOKEN),
                None,
            )
            .await,
        )
        .await;
        assert_eq!(detail["id"], model_id);
        assert_eq!(detail["hugging_face_id"], model_id);
        assert_eq!(
            response_json(
                call(
                    &app,
                    Method::GET,
                    "/v1/models/catalog/manifest/acme/private-chat",
                    Some(PUBLIC_TOKEN),
                    None,
                )
                .await,
            )
            .await["aggregate_sha256"],
            aggregate_hash
        );

        let alias = call(
            &app,
            Method::POST,
            "/v1/admin/models/aliases",
            Some(PUBLISHING_TOKEN),
            Some(json!({
                "alias_id": "private-chat",
                "display_name": "Darkbloom Private",
                "desired_build": model_id,
            })),
        )
        .await;
        assert_eq!(alias.status(), StatusCode::OK);
        let models =
            response_json(call(&app, Method::GET, "/v1/models", Some(PUBLIC_TOKEN), None).await)
                .await;
        let ids = models["data"]
            .as_array()
            .expect("model list")
            .iter()
            .filter_map(|model| model["id"].as_str())
            .collect::<Vec<_>>();
        assert_eq!(ids, ["private-chat"]);

        let admin_action = call(
            &app,
            Method::POST,
            "/v1/admin/models/acme/private-chat/capabilities",
            Some(ADMIN_TOKEN),
            Some(json!({"capabilities": ["vision", "tools"]})),
        )
        .await;
        assert_eq!(
            admin_action.status(),
            StatusCode::OK,
            "admin key must be accepted on publishing-or-admin model routes"
        );
        let capabilities: Vec<String> =
            sqlx::query_scalar("SELECT capabilities FROM public.model_registry WHERE id=$1")
                .bind(model_id)
                .fetch_one(&test.pool)
                .await
                .expect("capabilities");
        assert_eq!(capabilities, ["tools", "vision"]);

        assert_eq!(
            call(
                &app,
                Method::DELETE,
                "/v1/admin/models/aliases/private-chat",
                Some(PUBLISHING_TOKEN),
                None,
            )
            .await
            .status(),
            StatusCode::OK
        );
        let alias_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM public.model_aliases")
            .fetch_one(&test.pool)
            .await
            .expect("alias count");
        assert_eq!(alias_count, 0);

        artifacts.stop();
        test.stop().await;
    })
    .await;
}

#[tokio::test]
async fn telemetry_privacy_drain_mdm_and_encrypted_export_are_enforced() {
    with_isolated_database(|url| async move {
        let test = TestDatabase::start(&url).await;
        let export_root = temporary_directory("operations-export");
        fs::write(export_root.join("mdm.db"), b"sealed-state-secret").expect("state fixture");
        let export = StateExportConfig::encrypted(&export_root, "test-recipient", PROCESS_PUBLIC)
            .expect("state export config");
        let mut configured = settings(&Url::parse("http://127.0.0.1:9/").expect("URL"));
        configured.state_export = Some(export);
        let restart_settings = configured.clone();
        let state = Arc::new(
            OperationsStateBuilder::new(test.database.clone(), auth(), configured)
                .with_telemetry_capacity(2)
                .build()
                .expect("operations state"),
        );
        state
            .expect_mdm_command("mdm-command-1", "SecurityInfo")
            .expect("MDM command expectation");
        let app = router_with_state(Arc::clone(&state));

        let telemetry = call(
            &app,
            Method::POST,
            "/v1/telemetry/events",
            None,
            Some(json!({
                "events": [
                    {
                        "message": "one",
                        "machine_id": "spoofed-machine",
                        "account_id": "spoofed-account",
                        "fields": {
                        "model": "private-model",
                        "prompt": "must-not-be-retained",
                        "completion": "must-not-be-retained"
                    }},
                    {"message": "two", "fields": {"model": "private-model"}},
                    {"message": "three", "fields": {"model": "private-model"}}
                ]
            })),
        )
        .await;
        assert_eq!(telemetry.status(), StatusCode::ACCEPTED);
        let records = state.telemetry.records();
        assert_eq!(records.len(), 2);
        for record in records {
            assert_eq!(record["fields"]["model"], "private-model");
            assert!(record["fields"].get("prompt").is_none());
            assert!(record["fields"].get("completion").is_none());
            assert_eq!(record["machine_id"], "");
            assert_eq!(record["account_id"], "");
        }
        assert_eq!(state.telemetry.summary()["dropped"], 1);
        let over_limit = call(
            &app,
            Method::POST,
            "/v1/telemetry/events",
            None,
            Some(json!({
                "events": (0..28)
                    .map(|index| json!({"message": format!("rate-{index}")}))
                    .collect::<Vec<_>>()
            })),
        )
        .await;
        assert_eq!(over_limit.status(), StatusCode::TOO_MANY_REQUESTS);

        let restarted =
            OperationsStateBuilder::new(test.database.clone(), auth(), restart_settings.clone())
                .build()
                .expect("restart operations state");
        assert_eq!(
            restarted
                .telemetry_service()
                .process_once(Uuid::new_v4())
                .await
                .expect("deliver restart-safe durable telemetry"),
            3
        );
        let delivered: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM rust_coord.telemetry_events WHERE status = 'delivered'",
        )
        .fetch_one(&test.pool)
        .await
        .expect("count delivered telemetry");
        assert_eq!(delivered, 3);

        let mut sink = TestTelemetrySink::start().await;
        let sink_state = Arc::new(
            OperationsStateBuilder::new(test.database.clone(), auth(), restart_settings)
                .with_telemetry_settings(TelemetrySettings {
                    persistent_capacity: 2,
                    delivery_batch_size: 8,
                    maximum_delivery_attempts: 2,
                    lease_duration: Duration::from_secs(1),
                    retry_after: Duration::from_millis(1),
                    request_timeout: Duration::from_secs(2),
                    datadog: Some(DatadogTelemetrySettings {
                        api_key: Arc::from("datadog-test-key"),
                        logs_url: sink.url.clone(),
                        environment: Arc::from("test"),
                        service: Arc::from("coordinator-rs"),
                    }),
                })
                .build()
                .expect("Datadog telemetry state"),
        );
        let sink_app = router_with_state(Arc::clone(&sink_state));
        assert_eq!(
            call(
                &sink_app,
                Method::POST,
                "/v1/telemetry/events",
                None,
                Some(json!({
                    "events": [{
                        "message": "retry then deliver",
                        "fields": {
                            "model": "public-model",
                            "prompt": "never-forward"
                        }
                    }]
                })),
            )
            .await
            .status(),
            StatusCode::ACCEPTED
        );
        let sink_service = sink_state.telemetry_service();
        assert_eq!(
            sink_service
                .process_once(Uuid::new_v4())
                .await
                .expect("first Datadog attempt"),
            1
        );
        tokio::time::sleep(Duration::from_millis(5)).await;
        assert_eq!(
            sink_service
                .process_once(Uuid::new_v4())
                .await
                .expect("retry Datadog attempt"),
            1
        );
        let first = sink.next_batch().await;
        let retry = sink.next_batch().await;
        assert_eq!(
            first, retry,
            "retry must preserve the exact sanitized batch"
        );
        assert_eq!(first[0]["attributes"]["fields"]["model"], "public-model");
        assert!(first[0]["attributes"]["fields"].get("prompt").is_none());

        assert_eq!(
            call(
                &sink_app,
                Method::POST,
                "/v1/telemetry/events",
                None,
                Some(json!({"events": [{"message": "permanent drop"}]})),
            )
            .await
            .status(),
            StatusCode::ACCEPTED
        );
        assert_eq!(
            sink_service
                .process_once(Uuid::new_v4())
                .await
                .expect("permanent Datadog rejection"),
            1
        );
        let _ = sink.next_batch().await;
        let delivery = sink_service.metrics();
        assert_eq!(delivery.delivered, 1);
        assert_eq!(delivery.retried, 1);
        assert_eq!(delivery.dropped, 1);
        assert_eq!(delivery.sink_failures, 2);
        let retained: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM rust_coord.telemetry_events")
            .fetch_one(&test.pool)
            .await
            .expect("count bounded durable telemetry");
        assert_eq!(retained, 2);
        let metrics = response_json(
            call(
                &sink_app,
                Method::GET,
                "/v1/admin/metrics",
                Some(ADMIN_TOKEN),
                None,
            )
            .await,
        )
        .await;
        assert_eq!(metrics["durable_telemetry"]["delivered"], 1);
        assert_eq!(metrics["durable_telemetry"]["retried"], 1);
        assert_eq!(metrics["durable_telemetry"]["dropped"], 1);
        assert_eq!(metrics["durable_telemetry"]["sink_failures"], 2);
        assert_eq!(metrics["gauges"]["active_http_inference"], 0);
        assert_eq!(metrics["gauges"]["active_http_mutations"], 0);
        assert_eq!(metrics["gauges"]["active_external_operations"], 0);
        assert!(metrics["datadog_bridge"]["enabled"].is_boolean());
        assert!(metrics["datadog_bridge"]["dropped_full"].is_number());
        assert!(metrics["durable_states"].as_array().is_some_and(|states| {
            states.iter().any(|state| {
                state["relation"] == "telemetry_events"
                    && state["state"] == "pending"
                    && state["count"] == 0
            })
        }));
        assert_eq!(metrics["rollback_guard"]["go_fallback_safe"], true);
        assert_eq!(metrics["build"]["binary"], "rust");
        assert_eq!(
            metrics["gauges"]["migration_checksum_valid"],
            serde_json::Value::Bool(true)
        );
        sink.stop();

        assert_eq!(
            call(&app, Method::POST, "/v1/admin/drain", None, None)
                .await
                .status(),
            StatusCode::FORBIDDEN
        );
        let drained = response_json(
            call(
                &app,
                Method::POST,
                "/v1/admin/drain",
                Some(ADMIN_TOKEN),
                Some(json!({"draining": true})),
            )
            .await,
        )
        .await;
        assert_eq!(drained["draining"], true);
        let capacity = response_json(
            call(
                &app,
                Method::GET,
                "/v1/models/capacity",
                Some(PUBLIC_TOKEN),
                None,
            )
            .await,
        )
        .await;
        assert_eq!(capacity["draining"], true);

        let plist = "<plist><dict><key>CommandUUID</key><string>mdm-command-1</string>\
                     <key>SecurityInfo</key><dict/></dict></plist>";
        let webhook = json!({
            "topic": "acknowledge",
            "acknowledge_event": {
                "udid": "DEVICE1",
                "status": "Acknowledged",
                "raw_payload": STANDARD.encode(plist),
            }
        });
        assert_eq!(
            call(
                &app,
                Method::POST,
                "/v1/mdm/webhook",
                None,
                Some(webhook.clone()),
            )
            .await
            .status(),
            StatusCode::FORBIDDEN
        );
        let accepted = request(Method::POST, "/v1/mdm/webhook", None)
            .header("x-webhook-token", MDM_TOKEN)
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(
                serde_json::to_vec(&webhook).expect("webhook body"),
            ))
            .expect("webhook request");
        assert_eq!(
            app.clone()
                .oneshot(accepted)
                .await
                .expect("webhook")
                .status(),
            StatusCode::OK
        );
        let durable: (String, String) = sqlx::query_as(
            "SELECT event_id, event_kind FROM rust_coord.external_events WHERE source='micromdm'",
        )
        .fetch_one(&test.pool)
        .await
        .expect("durable MDM event");
        assert_eq!(
            durable,
            ("mdm-command-1".to_owned(), "SecurityInfo".to_owned())
        );
        let retry = request(Method::POST, "/v1/mdm/webhook", None)
            .header("x-webhook-token", MDM_TOKEN)
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(
                serde_json::to_vec(&webhook).expect("webhook body"),
            ))
            .expect("webhook retry");
        assert_eq!(
            app.clone().oneshot(retry).await.expect("retry").status(),
            StatusCode::OK
        );

        assert_eq!(
            call(
                &app,
                Method::GET,
                "/v1/admin/state-export",
                Some(PUBLIC_TOKEN),
                None,
            )
            .await
            .status(),
            StatusCode::FORBIDDEN
        );
        let export_response = call(
            &app,
            Method::GET,
            "/v1/admin/state-export",
            Some(ADMIN_TOKEN),
            None,
        )
        .await;
        assert_eq!(export_response.status(), StatusCode::OK);
        let export_body = response_bytes(export_response).await;
        assert!(
            !export_body
                .windows(b"sealed-state-secret".len())
                .any(|window| window == b"sealed-state-secret")
        );
        let envelope: Value = serde_json::from_slice(&export_body).expect("sealed export envelope");
        assert_eq!(envelope["file_count"], 1);
        let private: [u8; 32] = STANDARD
            .decode(PROCESS_PRIVATE)
            .expect("private key")
            .try_into()
            .expect("32-byte private key");
        let plaintext = open_box(
            &private,
            &BoxPayload {
                ephemeral_public_key: envelope["ephemeral_public_key"]
                    .as_str()
                    .expect("ephemeral public key")
                    .to_owned(),
                ciphertext: envelope["ciphertext"]
                    .as_str()
                    .expect("ciphertext")
                    .to_owned(),
            },
        )
        .expect("decrypt state export");
        assert!(plaintext.starts_with(b"DARKBLOOM-STATE-V1\0"));
        assert!(
            plaintext
                .windows(b"sealed-state-secret".len())
                .any(|window| window == b"sealed-state-secret")
        );

        let mut enrollment_required = settings(&Url::parse("http://127.0.0.1:9/").expect("URL"));
        enrollment_required.require_enrollment = true;
        assert!(matches!(
            OperationsStateBuilder::new(test.database.clone(), auth(), enrollment_required).build(),
            Err(OperationsBuildError::UnsignedEnrollmentForbidden)
        ));
        let mut invalid_otp = settings(&Url::parse("http://127.0.0.1:9/").expect("URL"));
        let mut otp = AdminOtpConfig::privy(
            "test-app",
            "test-secret",
            [Arc::<str>::from("admin@example.test")],
        )
        .expect("OTP config");
        otp.request_timeout = Duration::ZERO;
        invalid_otp.admin_otp = Some(otp);
        assert!(matches!(
            OperationsStateBuilder::new(test.database.clone(), auth(), invalid_otp).build(),
            Err(OperationsBuildError::InvalidAdminOtp)
        ));

        fs::remove_dir_all(export_root).expect("remove export fixture");
        test.stop().await;
    })
    .await;
}

struct TestDatabase {
    database: Database,
    ownership: CoordinatorOwnership,
    pool: PgPool,
}

impl TestDatabase {
    async fn start(url: &str) -> Self {
        seed_service_schema(url).await;
        let pool = PgPool::connect(url).await.expect("inspection pool");
        sqlx::query(
            "INSERT INTO public.publishing_api_keys (id,name,key_hash) VALUES ('publisher','test publisher',$1)",
        )
        .bind(digest_hex(PUBLISHING_TOKEN.as_bytes()))
        .execute(&pool)
        .await
        .expect("publishing key");
        let database = Database::connect(url, 16, Duration::from_secs(5))
            .await
            .expect("database");
        let ownership = CoordinatorOwnership::configure(&database, url, true)
            .await
            .expect("ownership");
        Self {
            database,
            ownership,
            pool,
        }
    }

    fn app(
        &self,
        settings: OperationsSettings,
        telemetry_capacity: usize,
        state_export: Option<StateExportConfig>,
    ) -> Router {
        let mut settings = settings;
        settings.state_export = state_export;
        router(
            OperationsStateBuilder::new(self.database.clone(), auth(), settings)
                .with_telemetry_capacity(telemetry_capacity)
                .build()
                .expect("operations state"),
        )
    }

    async fn stop(self) {
        self.pool.close().await;
        self.database
            .close(Duration::from_secs(2))
            .await
            .expect("close database");
        self.ownership.release().await.expect("release ownership");
    }
}

fn auth() -> OperationsAuth {
    OperationsAuth {
        public: PublicAuth::Bearer(ExactBearer::required(PUBLIC_TOKEN).expect("public auth")),
        admin: ExactBearer::required(ADMIN_TOKEN).expect("admin auth"),
        release: ExactBearer::required(RELEASE_TOKEN).expect("release auth"),
        publishing: PublishingAuth { enabled: true },
        mdm: MdmAuth::required(MDM_TOKEN).expect("MDM auth"),
    }
}

fn settings(artifact_origin: &Url) -> OperationsSettings {
    OperationsSettings {
        public_base_url: Url::parse("https://coordinator.test/").expect("coordinator URL"),
        model_cdn_url: artifact_origin.clone(),
        release_cdn_url: artifact_origin.clone(),
        provider_version: Arc::from("0.0.0-test"),
        build_commit: Arc::from("test-commit"),
        build_date: Arc::from("2026-07-11"),
        runtime_manifest: Some(json!({"backend": "mlx-swift"})),
        owner_epoch: 1,
        enrollment: None,
        require_enrollment: false,
        state_export: None,
        admin_otp: None::<AdminOtpConfig>,
    }
}

async fn call(
    app: &Router,
    method: Method,
    uri: &str,
    bearer: Option<&str>,
    body: Option<Value>,
) -> Response<Body> {
    let (request, body) = if let Some(body) = body {
        (
            request(method, uri, bearer).header(header::CONTENT_TYPE, "application/json"),
            Body::from(serde_json::to_vec(&body).expect("JSON request body")),
        )
    } else {
        (request(method, uri, bearer), Body::empty())
    };
    app.clone()
        .oneshot(request.body(body).expect("request"))
        .await
        .expect("response")
}

fn request(method: Method, uri: &str, bearer: Option<&str>) -> axum::http::request::Builder {
    let mut request = Request::builder().method(method).uri(uri);
    if let Some(token) = bearer {
        request = request.header(header::AUTHORIZATION, format!("Bearer {token}"));
    }
    request
}

async fn response_bytes(response: Response<Body>) -> Vec<u8> {
    response
        .into_body()
        .collect()
        .await
        .expect("response body")
        .to_bytes()
        .to_vec()
}

async fn response_text(response: Response<Body>) -> String {
    String::from_utf8(response_bytes(response).await).expect("UTF-8 response")
}

async fn response_json(response: Response<Body>) -> Value {
    serde_json::from_slice(&response_bytes(response).await).expect("JSON response")
}

#[derive(Clone)]
struct TelemetrySinkState {
    attempts: Arc<AtomicUsize>,
    batches: mpsc::Sender<Value>,
}

struct TestTelemetrySink {
    url: Url,
    batches: mpsc::Receiver<Value>,
    task: JoinHandle<()>,
}

impl TestTelemetrySink {
    async fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind telemetry sink");
        let address = listener.local_addr().expect("telemetry sink address");
        let (batches, receiver) = mpsc::channel(4);
        let state = TelemetrySinkState {
            attempts: Arc::new(AtomicUsize::new(0)),
            batches,
        };
        let app = Router::new()
            .route("/api/v2/logs", post(telemetry_sink))
            .with_state(state);
        let task = tokio::spawn(async move {
            axum::serve(listener, app)
                .await
                .expect("serve telemetry sink");
        });
        Self {
            url: Url::parse(&format!("http://{address}/api/v2/logs")).expect("telemetry sink URL"),
            batches: receiver,
            task,
        }
    }

    async fn next_batch(&mut self) -> Value {
        tokio::time::timeout(Duration::from_secs(2), self.batches.recv())
            .await
            .expect("telemetry sink timeout")
            .expect("telemetry sink channel")
    }

    fn stop(self) {
        self.task.abort();
    }
}

async fn telemetry_sink(
    State(state): State<TelemetrySinkState>,
    Json(batch): Json<Value>,
) -> StatusCode {
    let attempt = state.attempts.fetch_add(1, Ordering::SeqCst);
    state
        .batches
        .send(batch)
        .await
        .expect("record telemetry batch");
    match attempt {
        0 => StatusCode::INTERNAL_SERVER_ERROR,
        1 => StatusCode::ACCEPTED,
        _ => StatusCode::BAD_REQUEST,
    }
}

struct ArtifactServer {
    base_url: Url,
    task: JoinHandle<()>,
}

impl ArtifactServer {
    async fn start(files: BTreeMap<String, Vec<u8>>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind artifact server");
        let address = listener.local_addr().expect("artifact address");
        let files = Arc::new(files);
        let app = Router::new()
            .route("/{*path}", get(artifact).head(artifact))
            .with_state(files);
        let task = tokio::spawn(async move {
            axum::serve(listener, app)
                .await
                .expect("serve artifact fixture");
        });
        Self {
            base_url: Url::parse(&format!("http://{address}/")).expect("artifact URL"),
            task,
        }
    }

    fn stop(self) {
        self.task.abort();
    }
}

async fn artifact(
    State(files): State<Arc<BTreeMap<String, Vec<u8>>>>,
    request: AxumRequest,
) -> Response<Body> {
    let Some(bytes) = files.get(request.uri().path()) else {
        return Response::builder()
            .status(StatusCode::NOT_FOUND)
            .body(Body::empty())
            .expect("not found response");
    };
    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_LENGTH, bytes.len())
        .body(Body::from(bytes.clone()))
        .expect("artifact response")
}

struct ReleaseFixture {
    bundle: Vec<u8>,
    binary_hash: String,
    bundle_hash: String,
}

impl ReleaseFixture {
    fn registration(&self, base_url: &Url) -> Value {
        json!({
            "version": "1.2.3",
            "platform": "macos-arm64",
            "backend": "mlx-swift",
            "binary_hash": self.binary_hash,
            "bundle_hash": self.bundle_hash,
            "metallib_hash": digest_hex(b"metallib"),
            "url": base_url
                .join("releases/v1.2.3/darkbloom-bundle-macos-arm64.tar.gz")
                .expect("release URL")
                .to_string(),
            "changelog": "test release",
        })
    }
}

fn release_fixture() -> ReleaseFixture {
    let root = temporary_directory("operations-release");
    fs::create_dir(root.join("bin")).expect("release bin directory");
    let binary = b"test-provider-binary";
    fs::write(root.join("bin/darkbloom"), binary).expect("release binary");
    let archive = root.join("bundle.tar.gz");
    let status = Command::new("tar")
        .args(["-czf"])
        .arg(&archive)
        .arg("-C")
        .arg(&root)
        .arg("bin/darkbloom")
        .status()
        .expect("run tar");
    assert!(status.success(), "create release fixture");
    let bundle = fs::read(&archive).expect("read release fixture");
    fs::remove_dir_all(root).expect("remove release fixture");
    ReleaseFixture {
        binary_hash: digest_hex(binary),
        bundle_hash: digest_hex(&bundle),
        bundle,
    }
}

fn temporary_directory(prefix: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!("{prefix}-{}", Uuid::new_v4()));
    fs::create_dir(&path).expect("create temporary directory");
    path
}

fn digest_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}
