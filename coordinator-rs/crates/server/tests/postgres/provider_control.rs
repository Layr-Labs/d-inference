use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
    time::Duration,
};

use axum::{
    Router,
    body::{Body, to_bytes},
    extract::{Path, State},
    http::{HeaderMap, StatusCode, header},
    response::Response,
    routing::{get, post},
};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use darkbloom_coordinator_protocol::{
    v1::{AttestationResponse, Registration},
    v2::SessionEpoch,
};
use darkbloom_coordinator_server::{
    crypto::X25519PublicKey,
    database::{Database, DatabaseError},
    ownership::{CoordinatorOwnership, OwnershipError},
    provider_control::{MdmControlConfig, ProviderControlError, ProviderControlPlane},
    recovery::ExternalDisposition,
    surface::{
        identity::{IdentityState, MutationAuthority, PrivyVerifier, PrivyVerifierConfig},
        operations::AdmissionGate,
    },
    trust::{P256PublicIdentity, RegistrationTrust, TrustLevel},
};
use p256::{ecdsa::SigningKey, elliptic_curve::Generate as _};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};
use sqlx::PgPool;
use tokio::{net::TcpListener, sync::mpsc, task::JoinHandle, time::timeout};
use url::Url;
use uuid::Uuid;

use super::support::{seed_service_schema, with_isolated_database};

const MDM_KEY: &str = "local-micromdm-key";
const TOKEN: &str = "device-linked-provider-token";
const SERIAL: &str = "SERIAL-OBJECTIVE7";
const UDID: &str = "UDID-OBJECTIVE7";
const BINARY_HASH: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

#[tokio::test]
async fn device_token_identity_is_concurrent_key_bound_revocable_and_persisted() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        let mut mdm = MicroMdmServer::start().await;
        seed_provider_token(&pool, TOKEN, "provider-account").await;
        let admission = AdmissionGate::default();
        let control =
            build_control(database.clone(), mdm.base_url()).with_admission_gate(admission.clone());

        let (left, right) = tokio::join!(control.authenticate(TOKEN), control.authenticate(TOKEN));
        let left = left.expect("first concurrent authentication");
        let right = right.expect("second concurrent authentication");
        assert_eq!(left.provider_id, right.provider_id);
        assert_eq!(left.account_id.as_ref(), "provider-account");

        let (signing, trust) = registration_trust();
        let x25519 = X25519PublicKey::from_bytes([7; 32]).expect("x25519");
        control
            .bind_identity(&left, x25519, &trust.se_public_key)
            .await
            .expect("first-key binding");
        control
            .bind_identity(&right, x25519, &trust.se_public_key)
            .await
            .expect("idempotent concurrent binding");
        let (_, other_trust) = registration_trust();
        assert!(matches!(
            control
                .bind_identity(&left, x25519, &other_trust.se_public_key)
                .await,
            Err(ProviderControlError::IdentityRotation)
        ));

        let response = attestation_response(BINARY_HASH);
        let hardware = tokio::spawn({
            let control = control.clone();
            let left = left.clone();
            let trust = trust.clone();
            async move {
                control
                    .establish_hardware_trust(&left, SessionEpoch(1), &trust, &response)
                    .await
            }
        });
        let command = mdm.next_command().await;
        assert_eq!(command.udid, UDID);
        let restarted = build_control(database.clone(), mdm.base_url());
        assert_eq!(
            restarted
                .ingest_mdm_webhook(security_info(&command.uuid, UDID, true, "full"))
                .await
                .expect("restart-safe webhook"),
            ExternalDisposition::Applied
        );
        hardware
            .await
            .expect("hardware task")
            .expect("hardware trust");

        let registration = registration(x25519.to_base64(), TOKEN);
        control
            .persist_connected(
                &left,
                &registration,
                Uuid::new_v4(),
                SessionEpoch(1),
                &trust,
            )
            .await
            .expect("persist accepted provider");
        assert!(
            control
                .persist_heartbeat(left.provider_id, SessionEpoch(1))
                .await
                .expect("heartbeat")
        );
        let persisted: (bool, String, String, bool) = sqlx::query_as(
            r#"
            SELECT connected, account_id, trust_level, mdm_enrolled
            FROM public.providers
            WHERE id = $1
            "#,
        )
        .bind(left.provider_id.to_string())
        .fetch_one(&pool)
        .await
        .expect("persisted provider");
        assert_eq!(
            persisted,
            (
                true,
                "provider-account".to_owned(),
                "hardware".to_owned(),
                true
            )
        );

        sqlx::raw_sql(
            r#"
            CREATE FUNCTION delay_test_provider_heartbeat()
            RETURNS trigger
            LANGUAGE plpgsql
            AS $$
            BEGIN
                PERFORM pg_sleep(0.1);
                RETURN NEW;
            END;
            $$;
            CREATE TRIGGER delay_test_provider_heartbeat
            BEFORE UPDATE OF last_seen ON public.providers
            FOR EACH ROW
            EXECUTE FUNCTION delay_test_provider_heartbeat();
            "#,
        )
        .execute(&pool)
        .await
        .expect("install heartbeat delay");
        let delayed_provider_id = left.provider_id;
        let delayed_heartbeat = tokio::spawn({
            let control = control.clone();
            async move {
                control
                    .persist_heartbeat(delayed_provider_id, SessionEpoch(1))
                    .await
            }
        });
        timeout(Duration::from_secs(1), async {
            while admission.active_mutations() != 1 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("heartbeat entered mutation accounting");
        admission.set_draining(true);
        assert_eq!(admission.active_mutations(), 1);
        assert!(
            delayed_heartbeat
                .await
                .expect("delayed heartbeat task")
                .expect("delayed heartbeat")
        );
        assert_eq!(admission.active_mutations(), 0);
        let accepted_timestamp: i64 = sqlx::query_scalar(
            "SELECT (EXTRACT(EPOCH FROM last_seen) * 1000000)::BIGINT FROM public.providers WHERE id=$1",
        )
        .bind(left.provider_id.to_string())
        .fetch_one(&pool)
        .await
        .expect("accepted heartbeat timestamp");
        assert!(matches!(
            control
                .persist_heartbeat(left.provider_id, SessionEpoch(1))
                .await,
            Err(ProviderControlError::Draining)
        ));
        let rejected_timestamp: i64 = sqlx::query_scalar(
            "SELECT (EXTRACT(EPOCH FROM last_seen) * 1000000)::BIGINT FROM public.providers WHERE id=$1",
        )
        .bind(left.provider_id.to_string())
        .fetch_one(&pool)
        .await
        .expect("rejected heartbeat timestamp");
        assert_eq!(rejected_timestamp, accepted_timestamp);
        admission.set_draining(false);
        sqlx::raw_sql(
            r#"
            DROP TRIGGER delay_test_provider_heartbeat ON public.providers;
            DROP FUNCTION delay_test_provider_heartbeat();
            "#,
        )
        .execute(&pool)
        .await
        .expect("remove heartbeat delay");

        sqlx::query(
            "UPDATE public.provider_tokens SET active=FALSE, revoked_at=NOW() WHERE token_hash=$1",
        )
        .bind(secret_hash(TOKEN))
        .execute(&pool)
        .await
        .expect("revoke token");
        assert!(matches!(
            control
                .persist_connected(
                    &left,
                    &registration,
                    Uuid::new_v4(),
                    SessionEpoch(1),
                    &trust,
                )
                .await,
            Err(ProviderControlError::HardUntrusted)
        ));
        assert!(
            !control
                .persist_heartbeat(left.provider_id, SessionEpoch(1))
                .await
                .expect("revoked heartbeat")
        );
        control
            .persist_disconnected(left.provider_id, SessionEpoch(1), "credential revoked")
            .await
            .expect("persist disconnect");
        let session: (bool, Option<String>, String) = sqlx::query_as(
            r#"
            SELECT providers.connected, sessions.disconnected_at::TEXT,
                   sessions.disconnect_reason
            FROM public.providers AS providers
            JOIN public.provider_sessions AS sessions
              ON sessions.session_id = providers.session_id
            WHERE providers.id = $1
            "#,
        )
        .bind(left.provider_id.to_string())
        .fetch_one(&pool)
        .await
        .expect("closed provider session");
        assert!(!session.0);
        assert!(session.1.is_some());
        assert_eq!(session.2, "credential revoked");

        let before_ownership_loss: (i64, i64) = sqlx::query_as(
            r#"
            SELECT
                (EXTRACT(EPOCH FROM providers.last_seen) * 1000000)::BIGINT,
                (EXTRACT(EPOCH FROM sessions.last_seen) * 1000000)::BIGINT
            FROM public.providers AS providers
            JOIN public.provider_sessions AS sessions
              ON sessions.session_id = providers.session_id
            WHERE providers.id = $1
            "#,
        )
        .bind(left.provider_id.to_string())
        .fetch_one(&pool)
        .await
        .expect("heartbeat timestamps before ownership loss");
        sqlx::query(
            "UPDATE public.coordinator_ownership SET owner_id='replacement-owner', epoch=epoch+1 WHERE singleton",
        )
        .execute(&pool)
        .await
        .expect("replace database owner");
        assert!(matches!(
            control
                .persist_heartbeat(left.provider_id, SessionEpoch(1))
                .await,
            Err(ProviderControlError::Database(DatabaseError::Ownership(
                OwnershipError::Lost
            )))
        ));
        let after_ownership_loss: (i64, i64) = sqlx::query_as(
            r#"
            SELECT
                (EXTRACT(EPOCH FROM providers.last_seen) * 1000000)::BIGINT,
                (EXTRACT(EPOCH FROM sessions.last_seen) * 1000000)::BIGINT
            FROM public.providers AS providers
            JOIN public.provider_sessions AS sessions
              ON sessions.session_id = providers.session_id
            WHERE providers.id = $1
            "#,
        )
        .bind(left.provider_id.to_string())
        .fetch_one(&pool)
        .await
        .expect("heartbeat timestamps after ownership loss");
        assert_eq!(after_ownership_loss, before_ownership_loss);
        sqlx::query(
            "UPDATE public.coordinator_ownership SET owner_id=$1, epoch=$2 WHERE singleton",
        )
        .bind(ownership.fence().context().owner_id())
        .bind(ownership.fence().context().epoch())
        .execute(&pool)
        .await
        .expect("restore database owner");

        drop(signing);
        mdm.stop();
        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn owner_delete_revokes_token_invalidates_trust_and_blocks_reauthentication() {
    with_isolated_database(|url| async move {
        const LEGACY_TOKEN_ONE: &str = "legacy-owner-token-one";
        const LEGACY_TOKEN_TWO: &str = "legacy-owner-token-two";
        let (database, ownership, pool) = service_database(&url).await;
        let mdm = MicroMdmServer::start().await;
        seed_provider_token(&pool, TOKEN, "provider-account").await;
        let control = build_control(database.clone(), mdm.base_url());
        let identity = control
            .authenticate(TOKEN)
            .await
            .expect("authenticate token");
        let (_, trust) = registration_trust();
        control
            .bind_identity(
                &identity,
                X25519PublicKey::from_bytes([7; 32]).expect("x25519"),
                &trust.se_public_key,
            )
            .await
            .expect("bind provider identity");
        seed_provider_token(&pool, LEGACY_TOKEN_ONE, "provider-account").await;
        seed_provider_token(&pool, LEGACY_TOKEN_TWO, "provider-account").await;
        sqlx::query(
            r#"
            UPDATE public.providers
            SET
                serial_number=$2,
                session_epoch=3,
                hard_untrust_epoch=2,
                trust_level='hardware'
            WHERE id=$1
            "#,
        )
        .bind(identity.provider_id.to_string())
        .bind(SERIAL)
        .execute(&pool)
        .await
        .expect("seed provider deletion state");
        sqlx::query(
            r#"
            INSERT INTO public.provider_trust_reuse (
                se_pubkey, provider_id, serial, trust_level, binary_hash,
                sip_enabled, secure_boot_full, mda_udid, hard_untrust_epoch,
                enrolled, security_info_at, verified_at
            ) VALUES (
                $1,$2,$3,'hardware',$4,TRUE,TRUE,$5,2,TRUE,NOW(),NOW()
            )
            "#,
        )
        .bind(trust.se_public_key.as_base64())
        .bind(identity.provider_id.to_string())
        .bind(SERIAL)
        .bind(BINARY_HASH)
        .bind(UDID)
        .execute(&pool)
        .await
        .expect("seed reusable hardware trust");

        let ownership_fence = ownership.fence();
        let authority = ownership_fence.context();
        let verifier = PrivyVerifier::new(PrivyVerifierConfig::production(
            "test-app",
            Url::parse("http://127.0.0.1:9/jwks").expect("test JWKS URL"),
        ))
        .expect("test verifier");
        let identity_state = IdentityState::builder(
            pool.clone(),
            MutationAuthority::new(authority.owner_id(), authority.epoch())
                .expect("active mutation authority"),
            verifier,
        )
        .build()
        .expect("identity state");
        let deleted = identity_state
            .accounts()
            .delete_provider("provider-account", SERIAL)
            .await
            .expect("owner deletes provider");
        assert_eq!(deleted.rows_removed, 1);

        assert!(matches!(
            control.authenticate(TOKEN).await,
            Err(ProviderControlError::InvalidCredential)
        ));
        for legacy_token in [LEGACY_TOKEN_ONE, LEGACY_TOKEN_TWO] {
            assert!(
                matches!(
                    control.authenticate(legacy_token).await,
                    Err(ProviderControlError::InvalidCredential)
                ),
                "legacy-unlinked token {legacy_token:?} reauthenticated after owner delete"
            );
        }
        let legacy_token_state: (i64, i64) = sqlx::query_as(
            r#"
            SELECT
                COUNT(*) FILTER (WHERE active),
                COUNT(*) FILTER (
                    WHERE NOT active
                      AND revoked_at IS NOT NULL
                      AND updated_at >= revoked_at
                )
            FROM public.provider_tokens
            WHERE token_hash IN ($1, $2)
            "#,
        )
        .bind(secret_hash(LEGACY_TOKEN_ONE))
        .bind(secret_hash(LEGACY_TOKEN_TWO))
        .fetch_one(&pool)
        .await
        .expect("legacy owner token revocation state");
        assert_eq!(legacy_token_state, (0, 2));
        let token_state: (bool, bool, bool) = sqlx::query_as(
            r#"
            SELECT active, revoked_at IS NOT NULL, updated_at >= revoked_at
            FROM public.provider_tokens
            WHERE token_hash=$1
            "#,
        )
        .bind(secret_hash(TOKEN))
        .fetch_one(&pool)
        .await
        .expect("revoked token state");
        assert_eq!(token_state, (false, true, true));
        let durable_state: (i64, i64, i64, i64) = sqlx::query_as(
            r#"
            SELECT
                (SELECT COUNT(*) FROM public.providers WHERE id=$1),
                (SELECT COUNT(*) FROM public.provider_trust_reuse
                 WHERE provider_id=$1),
                (SELECT COUNT(*) FROM rust_coord.provider_hard_untrust_epochs
                 WHERE provider_id=$1::UUID),
                (SELECT hard_untrust_epoch
                 FROM rust_coord.provider_hard_untrust_epochs
                 WHERE provider_id=$1::UUID)
            "#,
        )
        .bind(identity.provider_id.to_string())
        .fetch_one(&pool)
        .await
        .expect("durable provider deletion state");
        assert_eq!(durable_state, (0, 0, 1, 3));

        mdm.stop();
        shutdown(database, ownership, pool).await;
    })
    .await;
}

#[tokio::test]
async fn mdm_tamper_and_stale_evidence_never_upgrade_and_tamper_hard_untrusts() {
    with_isolated_database(|url| async move {
        let (database, ownership, pool) = service_database(&url).await;
        let mut mdm = MicroMdmServer::start().await;
        seed_provider_token(&pool, TOKEN, "provider-account").await;
        let control = build_control(database.clone(), mdm.base_url());
        let identity = control.authenticate(TOKEN).await.expect("authenticate");
        let (_, trust) = registration_trust();
        let x25519 = X25519PublicKey::from_bytes([7; 32]).expect("x25519");
        control
            .bind_identity(&identity, x25519, &trust.se_public_key)
            .await
            .expect("bind identity");

        let tampered_response = attestation_response(
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        );
        let tampered = tokio::spawn({
            let control = control.clone();
            let identity = identity.clone();
            let trust = trust.clone();
            async move {
                control
                    .establish_hardware_trust(
                        &identity,
                        SessionEpoch(7),
                        &trust,
                        &tampered_response,
                    )
                    .await
            }
        });
        let command = mdm.next_command().await;
        assert_eq!(
            control
                .ingest_mdm_webhook(security_info(
                    &command.uuid,
                    "UDID-TAMPERED",
                    true,
                    "full",
                ))
                .await
                .expect("tampered webhook disposition"),
            ExternalDisposition::Rejected
        );
        assert!(matches!(
            tampered.await.expect("tampered task"),
            Err(ProviderControlError::PostureMismatch)
        ));
        let hard_epoch: i64 = sqlx::query_scalar(
            "SELECT hard_untrust_epoch FROM rust_coord.provider_hard_untrust_epochs WHERE provider_id=$1",
        )
        .bind(Uuid::from_bytes(*identity.provider_id.as_bytes()))
        .fetch_one(&pool)
        .await
        .expect("hard-untrust epoch");
        assert_eq!(hard_epoch, 7);

        let stale_response = attestation_response(
            "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        );
        let stale = tokio::spawn({
            let control = control.clone();
            let identity = identity.clone();
            let trust = trust.clone();
            async move {
                control
                    .establish_hardware_trust(
                        &identity,
                        SessionEpoch(8),
                        &trust,
                        &stale_response,
                    )
                    .await
            }
        });
        let command = mdm.next_command().await;
        sqlx::query(
            r#"
            UPDATE rust_coord.mdm_command_expectations
            SET issued_at=NOW()-INTERVAL '2 seconds',
                expires_at=NOW()-INTERVAL '1 second'
            WHERE command_uuid=$1
            "#,
        )
        .bind(&command.uuid)
        .execute(&pool)
        .await
        .expect("expire MDM expectation");
        assert_eq!(
            control
                .ingest_mdm_webhook(security_info(&command.uuid, UDID, true, "full"))
                .await
                .expect("stale webhook disposition"),
            ExternalDisposition::Rejected
        );
        assert!(matches!(
            stale.await.expect("stale task"),
            Err(ProviderControlError::MdmUnavailable)
        ));
        let stale_reuse: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM public.provider_trust_reuse WHERE binary_hash=$1",
        )
        .bind("cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc")
        .fetch_one(&pool)
        .await
        .expect("stale reuse count");
        assert_eq!(stale_reuse, 0);

        mdm.stop();
        shutdown(database, ownership, pool).await;
    })
    .await;
}

fn build_control(database: Database, base_url: Url) -> ProviderControlPlane {
    ProviderControlPlane::new(
        database,
        [],
        MdmControlConfig {
            base_url,
            api_key: Arc::from(MDM_KEY),
            request_timeout: Duration::from_secs(2),
            security_info_timeout: Duration::from_secs(2),
            trust_reuse_window: Duration::from_secs(60),
        },
    )
    .expect("provider control")
}

async fn service_database(url: &str) -> (Database, CoordinatorOwnership, PgPool) {
    seed_service_schema(url).await;
    let database = Database::connect(url, 16, Duration::from_secs(5))
        .await
        .expect("database");
    let ownership = CoordinatorOwnership::configure(&database, url, true)
        .await
        .expect("ownership");
    let pool = PgPool::connect(url).await.expect("inspection pool");
    (database, ownership, pool)
}

async fn shutdown(database: Database, ownership: CoordinatorOwnership, pool: PgPool) {
    pool.close().await;
    database
        .close(Duration::from_secs(2))
        .await
        .expect("close database");
    ownership.release().await.expect("release ownership");
}

async fn seed_provider_token(pool: &PgPool, token: &str, account_id: &str) {
    sqlx::query(
        "INSERT INTO public.provider_tokens (token_hash, account_id, label) VALUES ($1,$2,'device')",
    )
    .bind(secret_hash(token))
    .bind(account_id)
    .execute(pool)
    .await
    .expect("provider token");
}

fn registration_trust() -> (SigningKey, RegistrationTrust) {
    let signing = SigningKey::generate();
    let encoded = STANDARD.encode(signing.verifying_key().to_sec1_point(false));
    let se_public_key = P256PublicIdentity::from_base64(&encoded).expect("P-256 identity");
    let x25519_public_key = X25519PublicKey::from_bytes([7; 32]).expect("x25519");
    (
        signing,
        RegistrationTrust {
            level: TrustLevel::SelfSigned,
            se_public_key,
            x25519_public_key,
            serial_number: Some(Arc::from(SERIAL)),
            timestamp: Arc::from("2026-07-11T20:00:00Z"),
        },
    )
}

fn registration(public_key: String, auth_token: &str) -> Registration {
    serde_json::from_value(json!({
        "hardware": {
            "machine_model": "Mac15,12",
            "chip_name": "Apple M3",
            "chip_family": "M3",
            "chip_tier": "base",
            "memory_gb": 16,
            "memory_available_gb": 12,
            "cpu_cores": {"total": 8, "performance": 4, "efficiency": 4},
            "gpu_cores": 10,
            "memory_bandwidth_gbs": 100
        },
        "models": [],
        "backend": "mlx-swift",
        "version": "0.7.0",
        "public_key": public_key,
        "auth_token": auth_token
    }))
    .expect("registration")
}

fn attestation_response(binary_hash: &str) -> AttestationResponse {
    AttestationResponse {
        nonce: "fresh-nonce".to_owned(),
        signature: "verified-before-MDM".to_owned(),
        status_signature: "verified-before-MDM".to_owned(),
        public_key: X25519PublicKey::from_bytes([7; 32])
            .expect("x25519")
            .to_base64(),
        hypervisor_active: None,
        rdma_disabled: Some(true),
        sip_enabled: Some(true),
        secure_boot_enabled: Some(true),
        binary_hash: binary_hash.to_owned(),
        active_model_hash: String::new(),
        python_hash: String::new(),
        runtime_hash: String::new(),
        template_hashes: BTreeMap::new(),
        grpc_binary_hash: String::new(),
        model_hashes: BTreeMap::new(),
    }
}

fn security_info(command_uuid: &str, udid: &str, sip: bool, secure_boot: &str) -> Value {
    let sip = if sip { "<true/>" } else { "<false/>" };
    let plist = format!(
        concat!(
            r#"<?xml version="1.0"?><plist version="1.0"><dict>"#,
            r#"<key>CommandUUID</key><string>{}</string>"#,
            r#"<key>Status</key><string>Acknowledged</string>"#,
            r#"<key>SecurityInfo</key><dict>"#,
            r#"<key>SystemIntegrityProtectionEnabled</key>{}"#,
            r#"<key>SecureBootLevel</key><string>{}</string>"#,
            r#"<key>AuthenticatedRootVolumeEnabled</key><true/>"#,
            r#"</dict></dict></plist>"#
        ),
        command_uuid, sip, secure_boot
    );
    json!({
        "topic": "mdm.Acknowledge",
        "acknowledge_event": {
            "udid": udid,
            "status": "Acknowledged",
            "raw_payload": STANDARD.encode(plist),
        }
    })
}

fn secret_hash(token: &str) -> String {
    let digest = Sha256::digest(token.as_bytes());
    let mut output = String::with_capacity(64);
    for byte in digest {
        use std::fmt::Write as _;
        let _ = write!(output, "{byte:02x}");
    }
    output
}

#[derive(Clone, Debug)]
struct MdmCommand {
    uuid: String,
    udid: String,
}

#[derive(Clone)]
struct MicroMdmState {
    command_tx: mpsc::Sender<MdmCommand>,
    requests: Arc<Mutex<Vec<String>>>,
}

struct MicroMdmServer {
    base_url: Url,
    command_rx: mpsc::Receiver<MdmCommand>,
    task: JoinHandle<()>,
}

impl MicroMdmServer {
    async fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind MicroMDM");
        let address = listener.local_addr().expect("MicroMDM address");
        let (command_tx, command_rx) = mpsc::channel(8);
        let state = MicroMdmState {
            command_tx,
            requests: Arc::new(Mutex::new(Vec::new())),
        };
        let app = Router::new()
            .route("/v1/devices", post(mdm_devices))
            .route("/v1/commands/{udid}", post(mdm_command))
            .route("/push/{udid}", get(mdm_push))
            .with_state(state);
        let task = tokio::spawn(async move {
            axum::serve(listener, app).await.expect("serve MicroMDM");
        });
        Self {
            base_url: Url::parse(&format!("http://{address}/")).expect("MicroMDM URL"),
            command_rx,
            task,
        }
    }

    fn base_url(&self) -> Url {
        self.base_url.clone()
    }

    async fn next_command(&mut self) -> MdmCommand {
        timeout(Duration::from_secs(2), self.command_rx.recv())
            .await
            .expect("MicroMDM command timeout")
            .expect("MicroMDM command channel")
    }

    fn stop(self) {
        self.task.abort();
    }
}

async fn mdm_devices(
    State(state): State<MicroMdmState>,
    headers: HeaderMap,
    body: Body,
) -> Response {
    if !valid_basic_auth(&headers) {
        return Response::builder()
            .status(StatusCode::UNAUTHORIZED)
            .body(Body::empty())
            .expect("unauthorized response");
    }
    let body = to_bytes(body, 16 * 1024).await.expect("device query body");
    let input: Value = serde_json::from_slice(&body).expect("device query JSON");
    state
        .requests
        .lock()
        .expect("request log")
        .push("devices".to_owned());
    let devices = if input["serial_number"] == SERIAL {
        json!({"devices": [{
            "serial_number": SERIAL,
            "udid": UDID,
            "enrollment_status": true
        }]})
    } else {
        json!({"devices": []})
    };
    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(
            serde_json::to_vec(&devices).expect("device response JSON"),
        ))
        .expect("device response")
}

async fn mdm_command(
    State(state): State<MicroMdmState>,
    Path(udid): Path<String>,
    headers: HeaderMap,
    body: Body,
) -> StatusCode {
    if !valid_basic_auth(&headers) {
        return StatusCode::UNAUTHORIZED;
    }
    let body = to_bytes(body, 64 * 1024).await.expect("command body");
    let body = std::str::from_utf8(&body).expect("command XML");
    assert!(body.contains("<key>RequestType</key><string>SecurityInfo</string>"));
    let uuid = between(body, "<key>CommandUUID</key><string>", "</string>")
        .expect("command UUID")
        .to_owned();
    state
        .command_tx
        .send(MdmCommand { uuid, udid })
        .await
        .expect("record command");
    StatusCode::OK
}

async fn mdm_push(
    State(state): State<MicroMdmState>,
    Path(udid): Path<String>,
    headers: HeaderMap,
) -> StatusCode {
    if !valid_basic_auth(&headers) {
        return StatusCode::UNAUTHORIZED;
    }
    state
        .requests
        .lock()
        .expect("request log")
        .push(format!("push:{udid}"));
    StatusCode::OK
}

fn valid_basic_auth(headers: &HeaderMap) -> bool {
    headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        == Some(format!("Basic {}", STANDARD.encode(format!("micromdm:{MDM_KEY}"))).as_str())
}

fn between<'a>(value: &'a str, before: &str, after: &str) -> Option<&'a str> {
    let start = value.find(before)? + before.len();
    let end = value[start..].find(after)? + start;
    Some(&value[start..end])
}
