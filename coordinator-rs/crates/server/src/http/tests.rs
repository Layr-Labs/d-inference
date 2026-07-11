use std::{
    collections::BTreeMap,
    path::PathBuf,
    sync::Arc,
    time::{Duration, Instant},
};

use axum::{
    body::{Body, Bytes},
    http::{Request, StatusCode, header},
};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use darkbloom_coordinator_protocol::v1::{
    AttestationResponse, CoordinatorMessage, EncryptedPayload, ProviderMessage,
};
use darkbloom_coordinator_protocol::{
    crypto::{open_box, seal_box_with, seal_v2_frame},
    v2::{
        AttemptId, AttemptIdentity, BinaryFrameFlags, BinaryFrameHeader, BinaryFrameKind,
        CoordinatorControlMessage, Digest, LeaseId, Prepare, Prepared, ProviderControlMessage,
        ProviderProcessGenerationId, ProviderTerminal, RegistrationResponse, ReplayFenceAck,
        RequestId, ReservationId, Start, StartAck, StructuredError, StructuredErrorClass,
        TerminalDisposition, TerminalOutcome, TerminalSignature,
    },
};
use futures_util::{SinkExt, StreamExt, stream};
use p256::{
    ecdsa::{DerSignature, SigningKey, signature::Signer},
    elliptic_curve::Generate,
};
use sha2::{Digest as _, Sha256};
use tokio::{sync::Semaphore, task::JoinSet, time::timeout};
use tokio_tungstenite::{connect_async, tungstenite::Message};
use tower::ServiceExt as _;
use uuid::Uuid;

use crate::{
    pilot::{PilotConfig, PilotRuntime},
    request::next_rolling_digest,
};

#[allow(dead_code, unused_imports)]
#[path = "../../tests/postgres/support.rs"]
mod postgres_support;

use super::routes;

const PROCESS_PRIVATE: &str = "XasIfmJKikt54X+Lg4AO5m87sSkmGLb9HC+LJ/+I4Os=";
const PROCESS_PUBLIC: &str = "3p7bfXt9wbTTW2HC7OQ1Nz+DQ8hbeGdNrfx+FG+IK08=";
const PROVIDER_TOKEN: &str = "provider-token";
const ALTERNATE_PROVIDER_TOKEN: &str = "alternate-provider-token";
const CONSUMER_KEY: &str = "consumer-key";
const WEBSOCKET_RECEIVE_TIMEOUT: Duration = Duration::from_secs(10);
static RESOURCE_LOAD_TEST_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

type TestWebSocket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

#[tokio::test]
async fn explicit_http_surface_auth_body_bounds_and_capacity_are_enforced() {
    let (runtime, handle, state_directory) = test_runtime().await;
    let runtime_task = tokio::spawn(runtime.run());
    wait_ready(handle.clone()).await;
    let app = routes(Some(handle.clone()));

    let key = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/v1/encryption-key")
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("response");
    assert_eq!(key.status(), StatusCode::OK);

    let unauthorized = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/v1/models")
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("response");
    assert_eq!(unauthorized.status(), StatusCode::UNAUTHORIZED);

    let models = app
        .clone()
        .oneshot(authorized_request("/v1/models", Body::empty()))
        .await
        .expect("response");
    assert_eq!(models.status(), StatusCode::OK);

    let malformed = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/chat/completions")
                .header(header::AUTHORIZATION, format!("Bearer {CONSUMER_KEY}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from("{"))
                .expect("request"),
        )
        .await
        .expect("response");
    assert_eq!(malformed.status(), StatusCode::BAD_REQUEST);

    let mut deep = "0".to_owned();
    for _ in 0..=32 {
        deep = format!("[{deep}]");
    }
    let deep = format!(
        r#"{{"model":"darkbloom/pilot-text","messages":[{{"role":"user","content":"x"}}],"extra":{deep}}}"#
    );
    let tiny_array = format!(
        r#"{{"model":"darkbloom/pilot-text","messages":[{{"role":"user","content":"x"}}],"extra":[{}]}}"#,
        std::iter::repeat_n("{}", 4_097)
            .collect::<Vec<_>>()
            .join(",")
    );
    let tools_object = String::from(
        r#"{"model":"darkbloom/pilot-text","messages":[],"tools":{"type":"function"}}"#,
    );
    let tool_calls_object = String::from(
        r#"{"model":"darkbloom/pilot-text","messages":[{"role":"assistant","tool_calls":{}}]}"#,
    );
    for adversarial in [deep, tiny_array, tools_object, tool_calls_object] {
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/chat/completions")
                    .header(header::AUTHORIZATION, format!("Bearer {CONSUMER_KEY}"))
                    .header(header::CONTENT_TYPE, "application/json")
                    .body(Body::from(adversarial))
                    .expect("request"),
            )
            .await
            .expect("response");
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        assert_eq!(handle.input_budget_available(), 64 * 1024 * 1024);
    }

    let unknown_model = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/chat/completions")
                .header(header::AUTHORIZATION, format!("Bearer {CONSUMER_KEY}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(r#"{"model":"not-a-pilot-model"}"#))
                .expect("request"),
        )
        .await
        .expect("response");
    assert_eq!(unknown_model.status(), StatusCode::NOT_FOUND);

    let unsupported_media = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/chat/completions")
                .header(header::AUTHORIZATION, format!("Bearer {CONSUMER_KEY}"))
                .header(header::CONTENT_TYPE, "text/plain")
                .body(Body::from("{}"))
                .expect("request"),
        )
        .await
        .expect("response");
    assert_eq!(
        unsupported_media.status(),
        StatusCode::UNSUPPORTED_MEDIA_TYPE
    );

    let unsupported = app
        .clone()
        .oneshot(authorized_request("/v1/completions", Body::empty()))
        .await
        .expect("response");
    assert_eq!(unsupported.status(), StatusCode::NOT_FOUND);

    let oversized = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/chat/completions")
                .header(header::AUTHORIZATION, format!("Bearer {CONSUMER_KEY}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(vec![
                    b'x';
                    crate::pilot::MAX_CONSUMER_BODY_BYTES + 1
                ]))
                .expect("request"),
        )
        .await
        .expect("response");
    assert_eq!(oversized.status(), StatusCode::PAYLOAD_TOO_LARGE);
    assert_eq!(handle.input_budget_available(), 64 * 1024 * 1024);

    let no_provider = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/chat/completions")
                .header(header::AUTHORIZATION, format!("Bearer {CONSUMER_KEY}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    r#"{"model":"darkbloom/pilot-text","messages":[{"role":"user","content":"hi"}],"stream":true}"#,
                ))
                .expect("request"),
        )
        .await
        .expect("response");
    assert_eq!(no_provider.status(), StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(
        no_provider.headers().get(header::RETRY_AFTER),
        Some(&"1".parse().expect("header"))
    );

    handle.shutdown();
    runtime_task
        .await
        .expect("runtime join")
        .expect("runtime shutdown");
    let _ = std::fs::remove_dir_all(state_directory);
}

#[tokio::test]
async fn global_input_permit_is_reserved_before_body_read_and_restored_on_drop() {
    let mut config = test_config();
    config.input_budget_bytes = crate::pilot::INPUT_RESERVATION_BYTES;
    let state_directory = config.state_directory.clone();
    let (runtime, handle) = PilotRuntime::build(&config).await.expect("pilot runtime");
    let runtime_task = tokio::spawn(runtime.run());
    wait_ready(handle.clone()).await;
    let app = routes(Some(handle.clone()));

    let stalled = app.clone().oneshot(
        Request::builder()
            .method("POST")
            .uri("/v1/chat/completions")
            .header(header::AUTHORIZATION, format!("Bearer {CONSUMER_KEY}"))
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from_stream(stream::pending::<
                Result<Bytes, std::io::Error>,
            >()))
            .expect("stalled request"),
    );
    let stalled = tokio::spawn(stalled);
    timeout(Duration::from_secs(2), async {
        while handle.input_budget_available() != 0 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("input permit acquired before read");

    let rejected = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/chat/completions")
                .header(header::AUTHORIZATION, format!("Bearer {CONSUMER_KEY}"))
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    r#"{"model":"darkbloom/pilot-text","messages":[]}"#,
                ))
                .expect("second request"),
        )
        .await
        .expect("second response");
    assert_eq!(rejected.status(), StatusCode::TOO_MANY_REQUESTS);

    stalled.abort();
    let _ = stalled.await;
    timeout(Duration::from_secs(2), async {
        while handle.input_budget_available() != crate::pilot::INPUT_RESERVATION_BYTES {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("input permit restored");

    handle.shutdown();
    runtime_task
        .await
        .expect("runtime join")
        .expect("runtime shutdown");
    let _ = std::fs::remove_dir_all(state_directory);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn real_axum_websocket_v1_is_visible_but_never_inference_eligible() {
    let _resource_load_guard = RESOURCE_LOAD_TEST_LOCK.lock().await;
    let (runtime, handle, state_directory) = test_runtime().await;
    let runtime_task = tokio::spawn(runtime.run());
    wait_ready(handle.clone()).await;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let address = listener.local_addr().expect("address");
    let server_handle = handle.clone();
    let server = tokio::spawn(async move {
        axum::serve(listener, routes(Some(server_handle)))
            .await
            .expect("serve");
    });

    let (mut socket, _) = connect_async(format!("ws://{address}/ws/provider"))
        .await
        .expect("websocket");
    let signing_key = SigningKey::generate();
    socket
        .send(Message::Text(registration_wire(&signing_key).into()))
        .await
        .expect("registration");
    let challenge = next_text(&mut socket).await;
    let challenge: CoordinatorMessage = serde_json::from_str(&challenge).expect("challenge JSON");
    let CoordinatorMessage::AttestationChallenge(challenge) = challenge else {
        panic!("expected attestation challenge");
    };
    let response = challenge_response(&signing_key, &challenge.nonce, &challenge.timestamp);
    socket
        .send(Message::Text(
            serde_json::to_string(&ProviderMessage::AttestationResponse(response))
                .expect("response JSON")
                .into(),
        ))
        .await
        .expect("challenge response");
    let acknowledgement = next_text(&mut socket).await;
    let acknowledgement: serde_json::Value =
        serde_json::from_str(&acknowledgement).expect("ack JSON");
    assert_eq!(acknowledgement["type"], "register_ack");

    timeout(Duration::from_secs(2), async {
        while handle.visible_provider_count() != 1 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("provider visible");
    assert_eq!(handle.inference_provider_count(), 0);

    socket.close(None).await.expect("close");
    timeout(Duration::from_secs(2), async {
        while handle.visible_provider_count() != 0 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("provider removed");

    handle.shutdown();
    runtime_task
        .await
        .expect("runtime join")
        .expect("runtime shutdown");
    server.abort();
    let _ = server.await;
    let _ = std::fs::remove_dir_all(state_directory);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn one_thousand_concurrent_real_websocket_sessions_remain_bounded() {
    let _resource_load_guard = RESOURCE_LOAD_TEST_LOCK.lock().await;
    const SESSION_COUNT: usize = 1_000;
    const HANDSHAKE_CONCURRENCY: usize = 16;

    let mut config = test_config();
    config.provider_credentials = (0..SESSION_COUNT)
        .map(|index| {
            (
                darkbloom_coordinator_protocol::v2::ProviderId::new(
                    u128::try_from(index + 1)
                        .expect("provider index")
                        .to_be_bytes(),
                ),
                Arc::<str>::from(format!("load-provider-token-{index}")),
            )
        })
        .collect::<Vec<_>>()
        .into();
    let state_directory = config.state_directory.clone();
    let (runtime, handle) = PilotRuntime::build(&config).await.expect("pilot runtime");
    let runtime_task = tokio::spawn(runtime.run());
    wait_ready(handle.clone()).await;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let address = listener.local_addr().expect("address");
    let server_handle = handle.clone();
    let server = tokio::spawn(async move {
        axum::serve(listener, routes(Some(server_handle)))
            .await
            .expect("serve");
    });

    let signing_key = SigningKey::generate();
    let handshake_slots = Arc::new(Semaphore::new(HANDSHAKE_CONCURRENCY));
    let mut handshakes = JoinSet::new();
    for index in 0..SESSION_COUNT {
        let signing_key = signing_key.clone();
        let handshake_slots = handshake_slots.clone();
        handshakes.spawn(async move {
            let (mut socket, _) = connect_async(format!("ws://{address}/ws/provider"))
                .await
                .expect("load websocket");
            let permit = handshake_slots
                .acquire_owned()
                .await
                .expect("handshake slots");
            let started = Instant::now();
            let token = format!("load-provider-token-{index}");
            let generation = ProviderProcessGenerationId::new(
                u128::try_from(index + SESSION_COUNT + 1)
                    .expect("generation index")
                    .to_be_bytes(),
            );
            let _session =
                v2_handshake_with_token(&mut socket, &signing_key, generation, &token).await;
            drop(permit);
            (socket, started.elapsed())
        });
    }

    let sessions = timeout(Duration::from_secs(90), async {
        let mut sessions = Vec::with_capacity(SESSION_COUNT);
        while let Some(joined) = handshakes.join_next().await {
            sessions.push(joined.expect("handshake task"));
        }
        sessions
    })
    .await
    .expect("one thousand handshakes");
    assert_eq!(sessions.len(), SESSION_COUNT);
    wait_visible_count(&handle, SESSION_COUNT).await;
    assert_eq!(handle.inference_provider_count(), SESSION_COUNT);
    assert_eq!(handle.active_request_count(), 0);
    assert_eq!(handle.input_budget_available(), config.input_budget_bytes);
    assert_eq!(
        handle.response_budget_available(),
        config.response_budget_bytes
    );
    assert!(
        handle.provider_acceptor().remaining_capacity() <= config.maximum_sessions,
        "provider mailbox exceeded configured capacity"
    );
    assert!(
        handle.telemetry().remaining_capacity() <= config.telemetry_capacity,
        "telemetry mailbox exceeded configured capacity"
    );

    let mut latencies: Vec<_> = sessions.iter().map(|(_, latency)| *latency).collect();
    latencies.sort_unstable();
    assert_eq!(latencies.len(), SESSION_COUNT);
    let minimum = latencies[0];
    let p95 = latencies[SESSION_COUNT * 95 / 100 - 1];
    let p99 = latencies[SESSION_COUNT * 99 / 100 - 1];
    assert!(minimum <= p95);
    assert!(p95 <= p99);
    assert!(p99 <= latencies[SESSION_COUNT - 1]);

    let mut closes = JoinSet::new();
    for (mut socket, _) in sessions {
        closes.spawn(async move {
            let _ = socket.close(None).await;
        });
    }
    while let Some(closed) = closes.join_next().await {
        closed.expect("close task");
    }
    timeout(Duration::from_secs(10), async {
        while handle.visible_provider_count() != 0 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("all sessions drained");

    handle.shutdown();
    runtime_task
        .await
        .expect("runtime join")
        .expect("runtime shutdown");
    server.abort();
    let _ = server.await;
    let _ = std::fs::remove_dir_all(state_directory);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn replacement_replay_ack_historical_terminal_and_v2_to_v1_are_fenced() {
    let _resource_load_guard = RESOURCE_LOAD_TEST_LOCK.lock().await;
    let (runtime, handle, state_directory) = test_runtime().await;
    let runtime_task = tokio::spawn(runtime.run());
    wait_ready(handle.clone()).await;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let address = listener.local_addr().expect("address");
    let server_handle = handle.clone();
    let server = tokio::spawn(async move {
        axum::serve(listener, routes(Some(server_handle)))
            .await
            .expect("serve");
    });

    let signing_key = SigningKey::generate();
    let (mut old_socket, _) = connect_async(format!("ws://{address}/ws/provider"))
        .await
        .expect("old websocket");
    let old_generation = ProviderProcessGenerationId::new([2; 16]);
    let old_session = v2_handshake(&mut old_socket, &signing_key, old_generation).await;
    wait_inference_count(&handle, 1).await;

    let (mut current_socket, _) = connect_async(format!("ws://{address}/ws/provider"))
        .await
        .expect("replacement websocket");
    let current_generation = ProviderProcessGenerationId::new([3; 16]);
    let current_session = v2_handshake(&mut current_socket, &signing_key, current_generation).await;
    assert!(current_session.session_epoch > old_session.session_epoch);
    let historical = signed_historical_terminal(&signing_key, old_session);
    current_socket
        .send(Message::Text(
            serde_json::to_string(&ProviderControlMessage::Terminal(historical.clone()))
                .expect("immediate historical terminal JSON")
                .into(),
        ))
        .await
        .expect("immediate historical terminal after RegisterAck");
    wait_inference_count(&handle, 0).await;

    let mut proofs = Vec::new();
    let mut historical_ack = None;
    while proofs.len() < 2 || historical_ack.is_none() {
        let message: CoordinatorControlMessage =
            serde_json::from_str(&next_text(&mut current_socket).await)
                .expect("replacement control");
        match message {
            CoordinatorControlMessage::CoordinatorReplayFence(proof) => proofs.push(proof),
            CoordinatorControlMessage::TerminalAck(ack) => historical_ack = Some(ack),
            other => panic!("unexpected replacement control: {other:?}"),
        }
    }
    let first = &proofs[0];
    assert_eq!(first.provider_id, old_session.provider_id);
    assert_eq!(
        first.provider_process_generation,
        old_session.provider_process_generation
    );
    assert_eq!(first.through_session_epoch, old_session.session_epoch);

    let retry = &proofs[1];
    assert_eq!(retry.proof_id, first.proof_id);
    let terminal_ack = historical_ack.expect("historical terminal ACK");
    assert_eq!(terminal_ack.identity, historical.identity);
    assert_eq!(terminal_ack.disposition, TerminalDisposition::Late);
    assert_eq!(handle.inference_provider_count(), 0);

    current_socket
        .send(Message::Text(
            serde_json::to_string(&ProviderControlMessage::ReplayFenceAck(ReplayFenceAck {
                proof_id: first.proof_id,
                provider_id: first.provider_id,
                provider_process_generation: first.provider_process_generation,
            }))
            .expect("replay ACK JSON")
            .into(),
        ))
        .await
        .expect("replay ACK");
    wait_inference_count(&handle, 1).await;

    let (mut v1_socket, _) = connect_async(format!("ws://{address}/ws/provider"))
        .await
        .expect("v1 replacement websocket");
    v1_socket
        .send(Message::Text(registration_wire(&signing_key).into()))
        .await
        .expect("v1 registration");
    let challenge: CoordinatorMessage =
        serde_json::from_str(&next_text(&mut v1_socket).await).expect("challenge JSON");
    let CoordinatorMessage::AttestationChallenge(challenge) = challenge else {
        panic!("expected attestation challenge");
    };
    v1_socket
        .send(Message::Text(
            serde_json::to_string(&ProviderMessage::AttestationResponse(challenge_response(
                &signing_key,
                &challenge.nonce,
                &challenge.timestamp,
            )))
            .expect("challenge response JSON")
            .into(),
        ))
        .await
        .expect("challenge response");
    let acknowledgement: serde_json::Value =
        serde_json::from_str(&next_text(&mut v1_socket).await).expect("v1 register ACK");
    assert_eq!(acknowledgement["type"], "register_ack");
    wait_visible_count(&handle, 1).await;
    wait_inference_count(&handle, 0).await;

    v1_socket.close(None).await.expect("v1 close");
    handle.shutdown();
    runtime_task
        .await
        .expect("runtime join")
        .expect("runtime shutdown");
    server.abort();
    let _ = server.await;
    let _ = old_socket.close(None).await;
    let _ = current_socket.close(None).await;
    let _ = std::fs::remove_dir_all(state_directory);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn unacknowledged_replay_proof_survives_runtime_restart_and_promotes_current_session() {
    let _resource_load_guard = RESOURCE_LOAD_TEST_LOCK.lock().await;
    let config = test_config();
    let state_directory = config.state_directory.clone();
    let (runtime, handle) = PilotRuntime::build(&config).await.expect("first runtime");
    let runtime_task = tokio::spawn(runtime.run());
    wait_ready(handle.clone()).await;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("first bind");
    let address = listener.local_addr().expect("first address");
    let server_handle = handle.clone();
    let server = tokio::spawn(async move {
        axum::serve(listener, routes(Some(server_handle)))
            .await
            .expect("first serve");
    });

    let signing_key = SigningKey::generate();
    let (mut old_socket, _) = connect_async(format!("ws://{address}/ws/provider"))
        .await
        .expect("old websocket");
    let old_session = v2_handshake(
        &mut old_socket,
        &signing_key,
        ProviderProcessGenerationId::new([2; 16]),
    )
    .await;
    wait_inference_count(&handle, 1).await;
    let consumer = spawn_stream_request(reqwest::Client::new(), address);
    let prepare = receive_prepare(&mut old_socket).await;
    let historical_terminal = serve_v2_request_from_prepare_with_ack(
        &mut old_socket,
        &signing_key,
        old_session,
        11,
        prepare,
        false,
    )
    .await;
    let response = consumer
        .await
        .expect("consumer task")
        .expect("consumer request");
    assert_eq!(response.status(), StatusCode::OK);
    let _ = response.bytes().await.expect("consumer body");
    let (mut replacement_socket, _) = connect_async(format!("ws://{address}/ws/provider"))
        .await
        .expect("replacement websocket");
    let replacement_session = v2_handshake(
        &mut replacement_socket,
        &signing_key,
        ProviderProcessGenerationId::new([3; 16]),
    )
    .await;
    assert!(replacement_session.session_epoch > old_session.session_epoch);
    let pending: CoordinatorControlMessage =
        serde_json::from_str(&next_text(&mut replacement_socket).await).expect("pending proof");
    let CoordinatorControlMessage::CoordinatorReplayFence(pending) = pending else {
        panic!("expected replay fence");
    };
    assert_eq!(
        pending.provider_process_generation,
        old_session.provider_process_generation
    );

    handle.shutdown();
    runtime_task
        .await
        .expect("first runtime join")
        .expect("first runtime shutdown");
    server.abort();
    let _ = server.await;
    drop(old_socket);
    drop(replacement_socket);

    let (runtime, restarted_handle) = PilotRuntime::build(&config)
        .await
        .expect("restarted runtime");
    let runtime_task = tokio::spawn(runtime.run());
    wait_ready(restarted_handle.clone()).await;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("restart bind");
    let address = listener.local_addr().expect("restart address");
    let server_handle = restarted_handle.clone();
    let server = tokio::spawn(async move {
        axum::serve(listener, routes(Some(server_handle)))
            .await
            .expect("restart serve");
    });
    let (mut resumed_socket, _) = connect_async(format!("ws://{address}/ws/provider"))
        .await
        .expect("resumed websocket");
    let resumed = v2_handshake(
        &mut resumed_socket,
        &signing_key,
        ProviderProcessGenerationId::new([4; 16]),
    )
    .await;
    assert!(resumed.session_epoch > replacement_session.session_epoch);
    wait_inference_count(&restarted_handle, 0).await;
    let mut replayed = Vec::new();
    while replayed.len() < 2 {
        let message: CoordinatorControlMessage =
            serde_json::from_str(&next_text(&mut resumed_socket).await).expect("restarted proof");
        let CoordinatorControlMessage::CoordinatorReplayFence(proof) = message else {
            panic!("expected restarted replay fence");
        };
        if replayed.iter().all(
            |existing: &darkbloom_coordinator_protocol::v2::CoordinatorReplayFenceProof| {
                existing.proof_id != proof.proof_id
            },
        ) {
            replayed.push(proof);
        }
    }
    assert!(
        replayed
            .iter()
            .any(|proof| proof.proof_id == pending.proof_id)
    );
    for proof in replayed {
        resumed_socket
            .send(Message::Text(
                serde_json::to_string(&ProviderControlMessage::ReplayFenceAck(ReplayFenceAck {
                    proof_id: proof.proof_id,
                    provider_id: proof.provider_id,
                    provider_process_generation: proof.provider_process_generation,
                }))
                .expect("restarted replay ACK JSON")
                .into(),
            ))
            .await
            .expect("restarted replay ACK");
    }
    wait_inference_count(&restarted_handle, 1).await;
    resumed_socket
        .send(Message::Text(
            serde_json::to_string(&ProviderControlMessage::Terminal(
                historical_terminal.clone(),
            ))
            .expect("historical terminal JSON")
            .into(),
        ))
        .await
        .expect("historical terminal replay");
    let terminal_ack: CoordinatorControlMessage =
        serde_json::from_str(&next_text(&mut resumed_socket).await).expect("historical ACK");
    let CoordinatorControlMessage::TerminalAck(terminal_ack) = terminal_ack else {
        panic!("expected historical terminal ACK");
    };
    assert_eq!(
        terminal_ack.terminal_digest,
        historical_terminal.terminal_digest
    );
    assert_eq!(terminal_ack.disposition, TerminalDisposition::Settled);

    resumed_socket.close(None).await.expect("resumed close");
    restarted_handle.shutdown();
    runtime_task
        .await
        .expect("restarted runtime join")
        .expect("restarted runtime shutdown");
    server.abort();
    let _ = server.await;
    let _ = std::fs::remove_dir_all(state_directory);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn every_clean_v2_disconnect_creates_one_acknowledged_abort_tombstone() {
    let _resource_load_guard = RESOURCE_LOAD_TEST_LOCK.lock().await;
    let config = test_config();
    let state_directory = config.state_directory.clone();
    let (runtime, handle) = PilotRuntime::build(&config).await.expect("pilot runtime");
    let runtime_task = tokio::spawn(runtime.run());
    wait_ready(handle.clone()).await;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let address = listener.local_addr().expect("address");
    let server_handle = handle.clone();
    let server = tokio::spawn(async move {
        axum::serve(listener, routes(Some(server_handle)))
            .await
            .expect("serve");
    });
    let signing_key = SigningKey::generate();
    let mut previous = None;

    for generation_marker in 2..=5_u8 {
        let (mut socket, _) = connect_async(format!("ws://{address}/ws/provider"))
            .await
            .expect("websocket");
        let session = v2_handshake(
            &mut socket,
            &signing_key,
            ProviderProcessGenerationId::new([generation_marker; 16]),
        )
        .await;
        if let Some(previous) = previous {
            wait_inference_count(&handle, 0).await;
            let message: CoordinatorControlMessage =
                serde_json::from_str(&next_text(&mut socket).await).expect("replay proof");
            let CoordinatorControlMessage::CoordinatorReplayFence(proof) = message else {
                panic!("expected replay fence");
            };
            assert_eq!(proof.provider_process_generation, previous);
            socket
                .send(Message::Text(
                    serde_json::to_string(&ProviderControlMessage::ReplayFenceAck(
                        ReplayFenceAck {
                            proof_id: proof.proof_id,
                            provider_id: proof.provider_id,
                            provider_process_generation: proof.provider_process_generation,
                        },
                    ))
                    .expect("replay ACK JSON")
                    .into(),
                ))
                .await
                .expect("replay ACK");
        }
        wait_inference_count(&handle, 1).await;
        previous = Some(session.provider_process_generation);
        socket.close(None).await.expect("clean close");
        wait_visible_count(&handle, 0).await;
    }

    handle.shutdown();
    runtime_task
        .await
        .expect("runtime join")
        .expect("runtime shutdown");
    server.abort();
    let _ = server.await;
    let _ = std::fs::remove_dir_all(state_directory);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn definite_precontent_failure_uses_one_alternate_before_http_headers() {
    let _resource_load_guard = RESOURCE_LOAD_TEST_LOCK.lock().await;
    let mut config = test_config();
    config.provider_credentials = Arc::from([
        (
            darkbloom_coordinator_protocol::v2::ProviderId::new([1; 16]),
            Arc::from(PROVIDER_TOKEN),
        ),
        (
            darkbloom_coordinator_protocol::v2::ProviderId::new([2; 16]),
            Arc::from(ALTERNATE_PROVIDER_TOKEN),
        ),
    ]);
    let state_directory = config.state_directory.clone();
    let (runtime, handle) = PilotRuntime::build(&config).await.expect("pilot runtime");
    let runtime_task = tokio::spawn(runtime.run());
    wait_ready(handle.clone()).await;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let address = listener.local_addr().expect("address");
    let server_handle = handle.clone();
    let server = tokio::spawn(async move {
        axum::serve(listener, routes(Some(server_handle)))
            .await
            .expect("serve");
    });

    let first_key = SigningKey::generate();
    let (mut first, _) = connect_async(format!("ws://{address}/ws/provider"))
        .await
        .expect("first websocket");
    let first_session = v2_handshake_with_token(
        &mut first,
        &first_key,
        ProviderProcessGenerationId::new([3; 16]),
        PROVIDER_TOKEN,
    )
    .await;
    assert_eq!(first_session.provider_id.as_bytes(), &[1; 16]);

    let alternate_key = SigningKey::generate();
    let (mut alternate, _) = connect_async(format!("ws://{address}/ws/provider"))
        .await
        .expect("alternate websocket");
    let alternate_session = v2_handshake_with_token(
        &mut alternate,
        &alternate_key,
        ProviderProcessGenerationId::new([4; 16]),
        ALTERNATE_PROVIDER_TOKEN,
    )
    .await;
    assert_eq!(alternate_session.provider_id.as_bytes(), &[2; 16]);
    wait_inference_count(&handle, 2).await;

    let consumer = spawn_stream_request(reqwest::Client::new(), address);
    let rejected = receive_prepare(&mut first).await;
    first
        .send(Message::Text(
            serde_json::to_string(&ProviderControlMessage::StructuredError(StructuredError {
                identity: rejected.identity,
                class: StructuredErrorClass::Capacity,
                message: Some("definite precontent capacity failure".to_owned()),
            }))
            .expect("structured error JSON")
            .into(),
        ))
        .await
        .expect("structured error");
    serve_v2_request(&mut alternate, &alternate_key, alternate_session, 7).await;
    let response = consumer
        .await
        .expect("consumer task")
        .expect("consumer response");
    assert_eq!(response.status(), StatusCode::OK);
    let body = response.text().await.expect("response body");
    assert!(body.contains("\"content\":\"hello\""));
    assert!(body.contains("data: [DONE]"));
    wait_active_request_count(&handle, 0).await;

    first.close(None).await.expect("first close");
    alternate.close(None).await.expect("alternate close");
    handle.shutdown();
    runtime_task
        .await
        .expect("runtime join")
        .expect("runtime shutdown");
    server.abort();
    let _ = server.await;
    let _ = std::fs::remove_dir_all(state_directory);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn unknown_current_terminal_flood_fences_only_offending_provider() {
    let _resource_load_guard = RESOURCE_LOAD_TEST_LOCK.lock().await;
    let mut config = test_config();
    config.provider_credentials = Arc::from([
        (
            darkbloom_coordinator_protocol::v2::ProviderId::new([1; 16]),
            Arc::from(PROVIDER_TOKEN),
        ),
        (
            darkbloom_coordinator_protocol::v2::ProviderId::new([2; 16]),
            Arc::from(ALTERNATE_PROVIDER_TOKEN),
        ),
    ]);
    let state_directory = config.state_directory.clone();
    let (runtime, handle) = PilotRuntime::build(&config).await.expect("pilot runtime");
    let runtime_task = tokio::spawn(runtime.run());
    wait_ready(handle.clone()).await;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let address = listener.local_addr().expect("address");
    let server_handle = handle.clone();
    let server = tokio::spawn(async move {
        axum::serve(listener, routes(Some(server_handle)))
            .await
            .expect("serve");
    });

    let offender_key = SigningKey::generate();
    let (mut offender, _) = connect_async(format!("ws://{address}/ws/provider"))
        .await
        .expect("offender websocket");
    let offender_session = v2_handshake_with_token(
        &mut offender,
        &offender_key,
        ProviderProcessGenerationId::new([3; 16]),
        PROVIDER_TOKEN,
    )
    .await;

    let healthy_key = SigningKey::generate();
    let (mut healthy, _) = connect_async(format!("ws://{address}/ws/provider"))
        .await
        .expect("healthy websocket");
    let healthy_session = v2_handshake_with_token(
        &mut healthy,
        &healthy_key,
        ProviderProcessGenerationId::new([4; 16]),
        ALTERNATE_PROVIDER_TOKEN,
    )
    .await;
    wait_inference_count(&handle, 2).await;

    for marker in 1..=8 {
        let terminal = signed_unrouted_terminal(&offender_key, offender_session, marker);
        offender
            .send(Message::Text(
                serde_json::to_string(&ProviderControlMessage::Terminal(terminal))
                    .expect("unknown terminal JSON")
                    .into(),
            ))
            .await
            .expect("unknown terminal");
    }
    wait_inference_count(&handle, 1).await;

    let consumer = spawn_stream_request(reqwest::Client::new(), address);
    serve_v2_request(&mut healthy, &healthy_key, healthy_session, 9).await;
    let response = consumer
        .await
        .expect("consumer task")
        .expect("healthy consumer response");
    assert_eq!(response.status(), StatusCode::OK);
    assert!(
        response
            .text()
            .await
            .expect("healthy response body")
            .contains("\"content\":\"hello\"")
    );

    let _ = offender.close(None).await;
    healthy.close(None).await.expect("healthy close");
    handle.shutdown();
    runtime_task
        .await
        .expect("runtime join")
        .expect("runtime shutdown");
    server.abort();
    let _ = server.await;
    let _ = std::fs::remove_dir_all(state_directory);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn malicious_control_saturation_is_provider_local_and_keeps_runtime_ready() {
    let _resource_load_guard = RESOURCE_LOAD_TEST_LOCK.lock().await;
    let mut config = test_config();
    config.provider_credentials = Arc::from([
        (
            darkbloom_coordinator_protocol::v2::ProviderId::new([1; 16]),
            Arc::from(PROVIDER_TOKEN),
        ),
        (
            darkbloom_coordinator_protocol::v2::ProviderId::new([2; 16]),
            Arc::from(ALTERNATE_PROVIDER_TOKEN),
        ),
    ]);
    let state_directory = config.state_directory.clone();
    let (runtime, handle) = PilotRuntime::build(&config).await.expect("pilot runtime");
    let runtime_task = tokio::spawn(runtime.run());
    wait_ready(handle.clone()).await;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let address = listener.local_addr().expect("address");
    let server_handle = handle.clone();
    let server = tokio::spawn(async move {
        axum::serve(listener, routes(Some(server_handle)))
            .await
            .expect("serve");
    });

    let offender_key = SigningKey::generate();
    let (mut old_offender, _) = connect_async(format!("ws://{address}/ws/provider"))
        .await
        .expect("offender websocket");
    let old_offender_session = v2_handshake_with_token(
        &mut old_offender,
        &offender_key,
        ProviderProcessGenerationId::new([5; 16]),
        PROVIDER_TOKEN,
    )
    .await;
    wait_inference_count(&handle, 1).await;
    let (mut offender, _) = connect_async(format!("ws://{address}/ws/provider"))
        .await
        .expect("replacement offender websocket");
    let offender_session = v2_handshake_with_token(
        &mut offender,
        &offender_key,
        ProviderProcessGenerationId::new([7; 16]),
        PROVIDER_TOKEN,
    )
    .await;
    let replay: CoordinatorControlMessage =
        serde_json::from_str(&next_text(&mut offender).await).expect("offender replay proof");
    let CoordinatorControlMessage::CoordinatorReplayFence(replay) = replay else {
        panic!("expected offender replay proof");
    };
    offender
        .send(Message::Text(
            serde_json::to_string(&ProviderControlMessage::ReplayFenceAck(ReplayFenceAck {
                proof_id: replay.proof_id,
                provider_id: replay.provider_id,
                provider_process_generation: replay.provider_process_generation,
            }))
            .expect("offender replay ACK JSON")
            .into(),
        ))
        .await
        .expect("offender replay ACK");
    wait_inference_count(&handle, 1).await;

    let healthy_key = SigningKey::generate();
    let (mut healthy, _) = connect_async(format!("ws://{address}/ws/provider"))
        .await
        .expect("healthy websocket");
    let healthy_session = v2_handshake_with_token(
        &mut healthy,
        &healthy_key,
        ProviderProcessGenerationId::new([6; 16]),
        ALTERNATE_PROVIDER_TOKEN,
    )
    .await;
    wait_inference_count(&handle, 2).await;

    assert!(
        handle.exhaust_provider_control_capacity_for_test(offender_session.provider_id),
        "offender session must be current"
    );
    let terminal = signed_historical_terminal(&offender_key, old_offender_session);
    offender
        .send(Message::Text(
            serde_json::to_string(&ProviderControlMessage::Terminal(terminal))
                .expect("malicious terminal JSON")
                .into(),
        ))
        .await
        .expect("malicious terminal");
    wait_inference_count(&handle, 1).await;
    assert!(
        handle.is_ready(),
        "provider-local saturation cleared readiness"
    );

    let consumer = spawn_stream_request(reqwest::Client::new(), address);
    serve_v2_request(&mut healthy, &healthy_key, healthy_session, 10).await;
    let response = consumer
        .await
        .expect("consumer task")
        .expect("healthy consumer response");
    assert_eq!(response.status(), StatusCode::OK);
    assert!(
        response
            .text()
            .await
            .expect("healthy response body")
            .contains("\"content\":\"hello\"")
    );
    assert!(handle.is_ready());

    let _ = old_offender.close(None).await;
    let _ = offender.close(None).await;
    healthy.close(None).await.expect("healthy close");
    handle.shutdown();
    runtime_task
        .await
        .expect("runtime join")
        .expect("runtime shutdown");
    server.abort();
    let _ = server.await;
    let _ = std::fs::remove_dir_all(state_directory);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn request_renews_fleet_permit_beyond_initial_ttl_until_terminal() {
    let _resource_load_guard = RESOURCE_LOAD_TEST_LOCK.lock().await;
    let mut config = test_config();
    config.permit_lease_ttl = Duration::from_millis(40);
    config.request_timeout = Duration::from_secs(2);
    let state_directory = config.state_directory.clone();
    let (runtime, handle) = PilotRuntime::build(&config).await.expect("pilot runtime");
    let runtime_task = tokio::spawn(runtime.run());
    wait_ready(handle.clone()).await;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let address = listener.local_addr().expect("address");
    let server_handle = handle.clone();
    let server = tokio::spawn(async move {
        axum::serve(listener, routes(Some(server_handle)))
            .await
            .expect("serve");
    });

    let signing_key = SigningKey::generate();
    let (mut socket, _) = connect_async(format!("ws://{address}/ws/provider"))
        .await
        .expect("websocket");
    let session = v2_handshake(
        &mut socket,
        &signing_key,
        ProviderProcessGenerationId::new([2; 16]),
    )
    .await;
    wait_inference_count(&handle, 1).await;
    let consumer = spawn_stream_request(reqwest::Client::new(), address);
    let prepare = receive_prepare(&mut socket).await;
    tokio::time::sleep(Duration::from_millis(220)).await;
    serve_v2_request_from_prepare(&mut socket, &signing_key, session, 8, prepare).await;
    let response = consumer
        .await
        .expect("consumer task")
        .expect("consumer response");
    assert_eq!(response.status(), StatusCode::OK);
    let body = response.text().await.expect("response body");
    assert!(body.contains("data: [DONE]"));
    wait_active_request_count(&handle, 0).await;

    socket.close(None).await.expect("provider close");
    handle.shutdown();
    runtime_task
        .await
        .expect("runtime join")
        .expect("runtime shutdown");
    server.abort();
    let _ = server.await;
    let _ = std::fs::remove_dir_all(state_directory);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn consumer_disconnect_cancels_prepare_start_and_committed_body() {
    let _resource_load_guard = RESOURCE_LOAD_TEST_LOCK.lock().await;
    let mut config = test_config();
    config.response_budget_bytes = crate::pilot::RESPONSE_RESERVATION_BYTES;
    let state_directory = config.state_directory.clone();
    let (runtime, handle) = PilotRuntime::build(&config).await.expect("pilot runtime");
    let runtime_task = tokio::spawn(runtime.run());
    wait_ready(handle.clone()).await;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let address = listener.local_addr().expect("address");
    let server_handle = handle.clone();
    let server = tokio::spawn(async move {
        axum::serve(listener, routes(Some(server_handle)))
            .await
            .expect("serve");
    });

    let (mut socket, _) = connect_async(format!("ws://{address}/ws/provider"))
        .await
        .expect("websocket");
    let signing_key = SigningKey::generate();
    let session = v2_handshake(
        &mut socket,
        &signing_key,
        ProviderProcessGenerationId::new([2; 16]),
    )
    .await;
    wait_inference_count(&handle, 1).await;
    let client = reqwest::Client::new();

    let prepare_disconnect = spawn_stream_request(client.clone(), address);
    let prepare = receive_prepare(&mut socket).await;
    prepare_disconnect.abort();
    let _ = prepare_disconnect.await;
    assert_cancel_for(&mut socket, &prepare.identity).await;
    wait_active_request_count(&handle, 0).await;

    let start_disconnect = spawn_stream_request(client.clone(), address);
    let prepare = receive_prepare(&mut socket).await;
    let _start = send_prepared_and_receive_start(&mut socket, &prepare).await;
    start_disconnect.abort();
    let _ = start_disconnect.await;
    assert_cancel_for(&mut socket, &prepare.identity).await;
    wait_active_request_count(&handle, 0).await;

    let body_disconnect = spawn_stream_request(client, address);
    let prepare = receive_prepare(&mut socket).await;
    let _start = send_prepared_and_receive_start(&mut socket, &prepare).await;
    socket
        .send(Message::Text(
            serde_json::to_string(&ProviderControlMessage::StartAck(StartAck {
                identity: prepare.identity.clone(),
            }))
            .expect("StartAck JSON")
            .into(),
        ))
        .await
        .expect("StartAck");
    send_content_chunk(&mut socket, &prepare, session).await;
    let response = body_disconnect
        .await
        .expect("consumer task")
        .expect("consumer response");
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(handle.response_budget_available(), 0);
    let retained_body_rejection = reqwest::Client::new()
        .post(format!("http://{address}/v1/chat/completions"))
        .bearer_auth(CONSUMER_KEY)
        .header(header::CONTENT_TYPE, "application/json")
        .body(r#"{"model":"darkbloom/pilot-text","messages":[],"stream":true}"#)
        .send()
        .await
        .expect("retained-body response");
    assert_eq!(
        retained_body_rejection.status(),
        StatusCode::TOO_MANY_REQUESTS
    );
    drop(response);
    assert_cancel_for(&mut socket, &prepare.identity).await;
    wait_active_request_count(&handle, 0).await;
    timeout(Duration::from_secs(2), async {
        while handle.response_budget_available() != config.response_budget_bytes {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("response permit restored after body drop");

    socket.close(None).await.expect("provider close");
    handle.shutdown();
    runtime_task
        .await
        .expect("runtime join")
        .expect("runtime shutdown");
    server.abort();
    let _ = server.await;
    let _ = std::fs::remove_dir_all(state_directory);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn concurrent_http_requests_receive_interleaved_websocket_chunks_with_bounded_resources() {
    let _resource_load_guard = RESOURCE_LOAD_TEST_LOCK.lock().await;
    const REQUESTS: usize = 128;
    let mut config = test_config();
    config.maximum_requests = REQUESTS;
    config.input_budget_bytes = REQUESTS * crate::pilot::INPUT_RESERVATION_BYTES;
    let response_reservation = crate::pilot::RESPONSE_RESERVATION_BYTES;
    config.response_budget_bytes = REQUESTS * response_reservation;
    let state_directory = config.state_directory.clone();
    let (runtime, handle) = PilotRuntime::build(&config).await.expect("pilot runtime");
    let runtime_task = tokio::spawn(runtime.run());
    wait_ready(handle.clone()).await;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let address = listener.local_addr().expect("address");
    let server_handle = handle.clone();
    let server = tokio::spawn(async move {
        axum::serve(listener, routes(Some(server_handle)))
            .await
            .expect("serve");
    });

    let signing_key = SigningKey::generate();
    let (mut socket, _) = connect_async(format!("ws://{address}/ws/provider"))
        .await
        .expect("websocket");
    let session = v2_handshake(
        &mut socket,
        &signing_key,
        ProviderProcessGenerationId::new([2; 16]),
    )
    .await;
    wait_inference_count(&handle, 1).await;
    let descriptor_baseline = stable_descriptor_count().await;
    let fleet_mailbox_baseline = handle.fleet_reliable_remaining_capacity();

    let client = reqwest::Client::new();
    let mut consumers = JoinSet::new();
    for index in 0..REQUESTS {
        let client = client.clone();
        consumers.spawn(async move {
            let started = Instant::now();
            let sealed_nonstream = index % 2 == 0;
            let plaintext = format!(
                r#"{{"model":"darkbloom/pilot-text","messages":[{{"role":"user","content":"concurrent-{index}"}}],"stream":{},"max_completion_tokens":4}}"#,
                !sealed_nonstream
            );
            let sender_private =
                [u8::try_from(index % 251 + 1).expect("sender key byte"); 32];
            let request = client
                .post(format!("http://{address}/v1/chat/completions"))
                .bearer_auth(CONSUMER_KEY);
            let request = if sealed_nonstream {
                let coordinator_public: [u8; 32] = STANDARD
                    .decode(PROCESS_PUBLIC)
                    .expect("coordinator public")
                    .try_into()
                    .expect("32-byte key");
                let payload = seal_box_with(
                    &sender_private,
                    &coordinator_public,
                    &[u8::try_from(index % 251 + 1).expect("nonce byte"); 24],
                    plaintext.as_bytes(),
                )
                .expect("seal concurrent request");
                request
                    .header(header::CONTENT_TYPE, super::body::SEALED_CONTENT_TYPE)
                    .json(
                        &darkbloom_coordinator_protocol::crypto::SenderSealEnvelope {
                            kid: "test-process-key".to_owned(),
                            ephemeral_public_key: payload.ephemeral_public_key,
                            ciphertext: payload.ciphertext,
                        },
                    )
            } else {
                request
                    .header(header::CONTENT_TYPE, "application/json")
                    .body(plaintext)
            };
            let response = request.send().await.expect("consumer response");
            let status = response.status();
            let body = response.bytes().await.expect("consumer body");
            (status, body, sealed_nonstream, sender_private, started.elapsed())
        });
    }

    let mut prepares = Vec::with_capacity(REQUESTS);
    for _ in 0..REQUESTS {
        prepares.push(receive_prepare(&mut socket).await);
    }
    assert_eq!(handle.active_request_count(), REQUESTS);
    assert_eq!(handle.input_budget_available(), 0);
    assert_eq!(handle.response_budget_available(), 0);

    for prepare in &prepares {
        send_prepared(&mut socket, prepare).await;
    }
    let mut starts = Vec::with_capacity(REQUESTS);
    for _ in 0..REQUESTS {
        let message: CoordinatorControlMessage =
            serde_json::from_str(&next_text(&mut socket).await).expect("Start JSON");
        let CoordinatorControlMessage::Start(start) = message else {
            panic!("expected Start");
        };
        assert!(
            prepares
                .iter()
                .any(|prepare| prepare.identity == start.identity)
        );
        starts.push(start);
    }
    for start in starts {
        socket
            .send(Message::Text(
                serde_json::to_string(&ProviderControlMessage::StartAck(StartAck {
                    identity: start.identity,
                }))
                .expect("StartAck JSON")
                .into(),
            ))
            .await
            .expect("StartAck");
    }

    let chunks = [
        br#"data: {"id":"chatcmpl-concurrent","object":"chat.completion.chunk","created":1,"model":"darkbloom/pilot-text","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

"#
        .as_slice(),
        br#"data: {"id":"chatcmpl-concurrent","object":"chat.completion.chunk","created":1,"model":"darkbloom/pilot-text","choices":[{"index":0,"delta":{"content":"hello"},"finish_reason":"stop"}]}

"#
        .as_slice(),
        b"data: [DONE]\n\n".as_slice(),
    ];
    let cumulative_tokens = [0_u64, 1, 1];
    let mut rolling = [0_u8; 32];
    let mut rolling_digests = Vec::with_capacity(chunks.len());
    let mut response_hasher = Sha256::new();
    for (sequence, chunk) in chunks.iter().enumerate() {
        rolling = next_rolling_digest(
            rolling,
            u64::try_from(sequence).expect("sequence"),
            cumulative_tokens[sequence],
            chunk,
        );
        rolling_digests.push(rolling);
        response_hasher.update(chunk);
    }
    let response_hash = Digest::new(response_hasher.finalize().into());
    for (sequence, chunk) in chunks.iter().enumerate() {
        for (index, prepare) in prepares.iter().enumerate() {
            send_output_frame(
                &mut socket,
                prepare,
                u64::try_from(sequence).expect("sequence"),
                cumulative_tokens[sequence],
                rolling_digests[sequence],
                sequence + 1 == chunks.len(),
                u8::try_from((index * chunks.len() + sequence) % 251 + 1).expect("nonce byte"),
                chunk,
            )
            .await;
        }
    }
    for prepare in &prepares {
        send_terminal(&mut socket, &signing_key, prepare, response_hash, rolling).await;
    }
    for _ in 0..REQUESTS {
        let acknowledgement: CoordinatorControlMessage =
            serde_json::from_str(&next_text(&mut socket).await).expect("terminal ACK JSON");
        assert!(matches!(
            acknowledgement,
            CoordinatorControlMessage::TerminalAck(_)
        ));
    }

    let mut observed_latencies = Vec::with_capacity(REQUESTS);
    while let Some(joined) = consumers.join_next().await {
        let (status, body, sealed_nonstream, sender_private, latency) =
            joined.expect("consumer task");
        assert_eq!(status, StatusCode::OK);
        if sealed_nonstream {
            let envelope: serde_json::Value =
                serde_json::from_slice(&body).expect("sealed response envelope");
            let opened = open_box(
                &sender_private,
                &EncryptedPayload {
                    ephemeral_public_key: PROCESS_PUBLIC.to_owned(),
                    ciphertext: envelope["ciphertext"]
                        .as_str()
                        .expect("ciphertext")
                        .to_owned(),
                },
            )
            .expect("open sealed concurrent response");
            let completion: serde_json::Value =
                serde_json::from_slice(&opened).expect("nonstream completion");
            assert_eq!(completion["choices"][0]["message"]["content"], "hello");
        } else {
            let body = std::str::from_utf8(&body).expect("SSE UTF-8");
            assert!(body.contains("\"content\":\"hello\""));
            assert!(body.contains("data: [DONE]"));
        }
        observed_latencies.push(latency);
    }
    assert_eq!(observed_latencies.len(), REQUESTS);
    observed_latencies.sort_unstable();
    let p95 = observed_latencies[REQUESTS * 95 / 100 - 1];
    let p99 = observed_latencies[REQUESTS * 99 / 100 - 1];
    assert!(p95 <= Duration::from_secs(10), "HTTP p95 was {p95:?}");
    assert!(p99 <= Duration::from_secs(15), "HTTP p99 was {p99:?}");
    wait_active_request_count(&handle, 0).await;
    timeout(Duration::from_secs(2), async {
        while handle.telemetry().latency_summary().is_none() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("latency evidence");
    let latency = handle
        .telemetry()
        .latency_summary()
        .expect("minimum latency samples");
    assert_eq!(latency.samples, REQUESTS);
    assert!(latency.minimum <= latency.p95);
    assert!(latency.p95 <= latency.p99);
    assert!(latency.p99 <= latency.maximum);
    assert_eq!(handle.input_budget_available(), config.input_budget_bytes);
    assert_eq!(
        handle.response_budget_available(),
        config.response_budget_bytes
    );
    assert_eq!(
        handle.request_dispatcher().remaining_capacity(),
        config.request_queue_capacity
    );
    let fleet = handle.fleet_snapshot();
    assert_eq!(fleet.active_lease_count(), 0);
    let provider = fleet.providers().next().expect("provider runtime");
    assert_eq!(
        provider.effective_writer_items(),
        provider.writer_headroom().available_items()
    );
    assert_eq!(
        provider.effective_writer_bytes(),
        provider.writer_headroom().available_bytes()
    );
    assert_eq!(
        handle.fleet_reliable_remaining_capacity(),
        fleet_mailbox_baseline
    );
    drop(client);
    wait_descriptor_count_at_most(descriptor_baseline + 4).await;

    assert!(session.matches_attempt(&prepares[0].identity));
    socket.close(None).await.expect("provider close");
    handle.shutdown();
    runtime_task
        .await
        .expect("runtime join")
        .expect("runtime shutdown");
    server.abort();
    let _ = server.await;
    let _ = std::fs::remove_dir_all(state_directory);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn one_provider_serves_over_one_thousand_sequential_requests_without_writer_debit_leak() {
    let _resource_load_guard = RESOURCE_LOAD_TEST_LOCK.lock().await;
    const REQUESTS: usize = 1_025;
    let config = test_config();
    let state_directory = config.state_directory.clone();
    let (runtime, handle) = PilotRuntime::build(&config).await.expect("pilot runtime");
    let runtime_task = tokio::spawn(runtime.run());
    wait_ready(handle.clone()).await;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let address = listener.local_addr().expect("address");
    let server_handle = handle.clone();
    let server = tokio::spawn(async move {
        axum::serve(listener, routes(Some(server_handle)))
            .await
            .expect("serve");
    });

    let signing_key = SigningKey::generate();
    let (mut socket, _) = connect_async(format!("ws://{address}/ws/provider"))
        .await
        .expect("websocket");
    v2_handshake(
        &mut socket,
        &signing_key,
        ProviderProcessGenerationId::new([2; 16]),
    )
    .await;
    wait_inference_count(&handle, 1).await;
    let descriptor_baseline = stable_descriptor_count().await;
    let fleet_mailbox_baseline = handle.fleet_reliable_remaining_capacity();
    let client = reqwest::Client::new();
    let chunks = [
        br#"data: {"id":"chatcmpl-sequential","object":"chat.completion.chunk","created":1,"model":"darkbloom/pilot-text","choices":[{"index":0,"delta":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}

"#
        .as_slice(),
        b"data: [DONE]\n\n".as_slice(),
    ];
    let mut rolling = [0_u8; 32];
    let mut rolling_digests = Vec::with_capacity(chunks.len());
    let mut response_hasher = Sha256::new();
    for (sequence, chunk) in chunks.iter().enumerate() {
        rolling = next_rolling_digest(
            rolling,
            u64::try_from(sequence).expect("sequence"),
            1,
            chunk,
        );
        rolling_digests.push(rolling);
        response_hasher.update(chunk);
    }
    let response_hash = Digest::new(response_hasher.finalize().into());
    let mut latencies = Vec::with_capacity(REQUESTS);

    for index in 0..REQUESTS {
        let client = client.clone();
        let consumer = tokio::spawn(async move {
            let started = Instant::now();
            let response = client
                .post(format!("http://{address}/v1/chat/completions"))
                .bearer_auth(CONSUMER_KEY)
                .header(header::CONTENT_TYPE, "application/json")
                .body(format!(
                    r#"{{"model":"darkbloom/pilot-text","messages":[{{"role":"user","content":"sequential-{index}"}}],"stream":true,"max_completion_tokens":4}}"#
                ))
                .send()
                .await
                .expect("consumer response");
            let status = response.status();
            let body = response.bytes().await.expect("consumer body");
            (status, body, started.elapsed())
        });

        let prepare = receive_prepare(&mut socket).await;
        send_prepared(&mut socket, &prepare).await;
        let message: CoordinatorControlMessage =
            serde_json::from_str(&next_text(&mut socket).await).expect("Start JSON");
        let CoordinatorControlMessage::Start(start) = message else {
            panic!("expected Start");
        };
        socket
            .send(Message::Text(
                serde_json::to_string(&ProviderControlMessage::StartAck(StartAck {
                    identity: start.identity,
                }))
                .expect("StartAck JSON")
                .into(),
            ))
            .await
            .expect("StartAck");
        for (sequence, chunk) in chunks.iter().enumerate() {
            send_output_frame(
                &mut socket,
                &prepare,
                u64::try_from(sequence).expect("sequence"),
                1,
                rolling_digests[sequence],
                sequence + 1 == chunks.len(),
                u8::try_from((index * chunks.len() + sequence) % 251 + 1).expect("nonce byte"),
                chunk,
            )
            .await;
        }
        send_terminal(&mut socket, &signing_key, &prepare, response_hash, rolling).await;
        let acknowledgement: CoordinatorControlMessage =
            serde_json::from_str(&next_text(&mut socket).await).expect("terminal ACK JSON");
        assert!(matches!(
            acknowledgement,
            CoordinatorControlMessage::TerminalAck(_)
        ));
        let (status, body, latency) = consumer.await.expect("consumer task");
        assert_eq!(status, StatusCode::OK, "request {index}");
        assert!(
            std::str::from_utf8(&body)
                .expect("SSE UTF-8")
                .contains("\"content\":\"ok\"")
        );
        latencies.push(latency);
    }

    wait_active_request_count(&handle, 0).await;
    latencies.sort_unstable();
    assert_eq!(latencies.len(), REQUESTS);
    let p95 = latencies[REQUESTS * 95 / 100 - 1];
    let p99 = latencies[REQUESTS * 99 / 100 - 1];
    assert!(p95 <= Duration::from_secs(2), "sequential p95 was {p95:?}");
    assert!(p99 <= Duration::from_secs(3), "sequential p99 was {p99:?}");
    let fleet = handle.fleet_snapshot();
    assert_eq!(fleet.active_lease_count(), 0);
    let provider = fleet.providers().next().expect("provider runtime");
    assert_eq!(
        provider.effective_writer_items(),
        provider.writer_headroom().available_items()
    );
    assert_eq!(
        provider.effective_writer_bytes(),
        provider.writer_headroom().available_bytes()
    );
    assert_eq!(
        handle.fleet_reliable_remaining_capacity(),
        fleet_mailbox_baseline
    );
    assert_eq!(handle.input_budget_available(), config.input_budget_bytes);
    assert_eq!(
        handle.response_budget_available(),
        config.response_budget_bytes
    );
    assert_eq!(
        handle.request_dispatcher().remaining_capacity(),
        config.request_queue_capacity
    );
    assert!(
        handle
            .telemetry()
            .latency_summary()
            .is_some_and(|summary| summary.samples >= REQUESTS)
    );
    drop(client);
    wait_descriptor_count_at_most(descriptor_baseline + 4).await;

    socket.close(None).await.expect("provider close");
    handle.shutdown();
    runtime_task
        .await
        .expect("runtime join")
        .expect("runtime shutdown");
    server.abort();
    let _ = server.await;
    let _ = std::fs::remove_dir_all(state_directory);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn real_v2_plain_and_sender_sealed_streaming_and_nonstreaming_round_trip() {
    let _resource_load_guard = RESOURCE_LOAD_TEST_LOCK.lock().await;
    let (runtime, handle, state_directory) = test_runtime().await;
    let runtime_task = tokio::spawn(runtime.run());
    wait_ready(handle.clone()).await;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let address = listener.local_addr().expect("address");
    let server_handle = handle.clone();
    let server = tokio::spawn(async move {
        axum::serve(listener, routes(Some(server_handle)))
            .await
            .expect("serve");
    });

    let (mut socket, _) = connect_async(format!("ws://{address}/ws/provider"))
        .await
        .expect("websocket");
    let signing_key = SigningKey::generate();
    let generation = ProviderProcessGenerationId::new([2; 16]);
    let session = v2_handshake(&mut socket, &signing_key, generation).await;
    timeout(Duration::from_secs(2), async {
        while handle.inference_provider_count() != 1 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("provider inference eligible");
    let provider = tokio::spawn(async move {
        for request_number in 0..4 {
            serve_v2_request(&mut socket, &signing_key, session, request_number).await;
        }
        socket.close(None).await.expect("provider close");
    });

    let client = reqwest::Client::new();
    for (streaming, sealed) in [(true, false), (false, false), (true, true), (false, true)] {
        let plaintext = format!(
            concat!(
                r#"{{"model":"darkbloom/pilot-text","messages":[{{"role":"user","#,
                r#""content":"round trip"}}],"stream":{streaming},"max_completion_tokens":4}}"#
            ),
            streaming = streaming,
        );
        let mut request = client
            .post(format!("http://{address}/v1/chat/completions"))
            .bearer_auth(CONSUMER_KEY);
        let sender_private = [9_u8; 32];
        if sealed {
            let payload = seal_box_with(
                &sender_private,
                &STANDARD
                    .decode(PROCESS_PUBLIC)
                    .expect("coordinator public")
                    .try_into()
                    .expect("32-byte key"),
                &[7; 24],
                plaintext.as_bytes(),
            )
            .expect("sender seal");
            let envelope = darkbloom_coordinator_protocol::crypto::SenderSealEnvelope {
                kid: "test-process-key".to_owned(),
                ephemeral_public_key: payload.ephemeral_public_key,
                ciphertext: payload.ciphertext,
            };
            request = request
                .header(header::CONTENT_TYPE, super::body::SEALED_CONTENT_TYPE)
                .json(&envelope);
        } else {
            request = request
                .header(header::CONTENT_TYPE, "application/json")
                .body(plaintext);
        }
        let response = request.send().await.expect("consumer response");
        assert_eq!(response.status(), StatusCode::OK);
        let headers = response.headers().clone();
        let bytes = response.bytes().await.expect("response body");
        let opened = if sealed && streaming {
            open_sealed_sse(&bytes, &sender_private)
        } else if sealed {
            let envelope: serde_json::Value =
                serde_json::from_slice(&bytes).expect("sealed response envelope");
            open_box(
                &sender_private,
                &EncryptedPayload {
                    ephemeral_public_key: PROCESS_PUBLIC.to_owned(),
                    ciphertext: envelope["ciphertext"]
                        .as_str()
                        .expect("ciphertext")
                        .to_owned(),
                },
            )
            .expect("open sealed response")
        } else {
            bytes.to_vec()
        };
        if streaming {
            let text = String::from_utf8(opened).expect("stream UTF-8");
            assert!(text.contains("\"content\":\"hello\""));
            assert!(text.contains("data: [DONE]"));
            assert_eq!(
                headers.get(header::CONTENT_TYPE),
                Some(&"text/event-stream".parse().expect("header"))
            );
        } else {
            let value: serde_json::Value = serde_json::from_slice(&opened).expect("nonstream JSON");
            assert_eq!(value["object"], "chat.completion");
            assert_eq!(value["choices"][0]["message"]["content"], "hello");
        }
        if sealed {
            assert_eq!(
                headers.get("x-eigen-sealed"),
                Some(&"true".parse().expect("header"))
            );
        }
    }

    provider.await.expect("provider task");
    handle.shutdown();
    runtime_task
        .await
        .expect("runtime join")
        .expect("runtime shutdown");
    server.abort();
    let _ = server.await;
    let _ = std::fs::remove_dir_all(state_directory);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn paid_axum_websocket_request_commits_once_before_terminal_ack_and_replay() {
    postgres_support::with_isolated_database(|url| async move {
        let _resource_load_guard = RESOURCE_LOAD_TEST_LOCK.lock().await;
        postgres_support::seed_service_schema(&url).await;
        let pool = sqlx::PgPool::connect(&url)
            .await
            .expect("connect paid pilot assertions");
        sqlx::query(
            "INSERT INTO public.balances (account_id, balance_micro_usd, withdrawable_micro_usd) VALUES ('consumer', 100, 100)",
        )
        .execute(&pool)
        .await
        .expect("seed paid consumer");
        let database = crate::database::Database::connect(&url, 8, Duration::from_secs(3))
            .await
            .expect("connect paid pilot database");
        let ownership =
            crate::ownership::CoordinatorOwnership::configure(&database, &url, true)
                .await
                .expect("configure paid pilot ownership");

        let mut config = test_config();
        let state_directory = config.state_directory.clone();
        let provider_id = darkbloom_coordinator_protocol::v2::ProviderId::new([1; 16]);
        config.consumer_credentials = Arc::from([crate::pilot::ConsumerCredentialEntry {
            raw_key: Arc::from(CONSUMER_KEY),
            account_id: Some(
                crate::ledger::AccountId::new("consumer").expect("consumer account"),
            ),
            api_key_id: Arc::from("paid-key"),
        }]);
        config.provider_beneficiaries = Arc::from([crate::pilot::ProviderBeneficiaryEntry {
            provider_id,
            account_id: crate::ledger::AccountId::new("provider").expect("provider account"),
        }]);
        config.paid_billing = Some(crate::pilot::PaidBillingPolicy {
            platform_account_id: crate::ledger::AccountId::new("platform")
                .expect("platform account"),
            referral_account_id: None,
            pricing_version: crate::ledger::Version::new(1).expect("pricing version"),
            rounding_version: crate::ledger::Version::new(1).expect("rounding version"),
            base_reservation: crate::ledger::LedgerAmount::new(1).expect("base reservation"),
            input_micro_usd_per_million: crate::ledger::LedgerAmount::new(1_000_000)
                .expect("input rate"),
            output_micro_usd_per_million: crate::ledger::LedgerAmount::new(2_000_000)
                .expect("output rate"),
            provider_share_ppm: 750_000,
            referral_share_ppm: 0,
        });
        config.trust_floor = crate::trust::TrustFloor::PUBLIC;
        config.test_established_trust = Some(crate::trust::TrustLevel::Hardware);
        let (runtime, handle) = PilotRuntime::build_durable(
            &config,
            database.clone(),
            ownership.status(),
        )
        .await
        .expect("paid pilot runtime");
        let runtime_task = tokio::spawn(runtime.run());
        wait_ready(handle.clone()).await;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind paid pilot");
        let address = listener.local_addr().expect("paid pilot address");
        let server_handle = handle.clone();
        let server = tokio::spawn(async move {
            axum::serve(listener, routes(Some(server_handle)))
                .await
                .expect("serve paid pilot");
        });

        let (mut socket, _) = connect_async(format!("ws://{address}/ws/provider"))
            .await
            .expect("paid provider websocket");
        let signing_key = SigningKey::generate();
        let session = v2_handshake(
            &mut socket,
            &signing_key,
            ProviderProcessGenerationId::new([42; 16]),
        )
        .await;
        wait_inference_count(&handle, 1).await;
        let replay_handle = handle.clone();
        let provider = tokio::spawn(async move {
            let prepare = receive_prepare(&mut socket).await;
            let terminal =
                serve_v2_request_from_prepare(&mut socket, &signing_key, session, 0, prepare)
                    .await;
            wait_active_request_count(&replay_handle, 0).await;
            socket
                .send(Message::Text(
                    serde_json::to_string(&ProviderControlMessage::Terminal(terminal.clone()))
                        .expect("terminal replay JSON")
                        .into(),
                ))
                .await
                .expect("terminal replay");
            let acknowledgement: CoordinatorControlMessage =
                serde_json::from_str(&next_text(&mut socket).await)
                    .expect("terminal replay ACK JSON");
            let CoordinatorControlMessage::TerminalAck(acknowledgement) = acknowledgement else {
                panic!("expected replay terminal ACK");
            };
            assert_eq!(acknowledgement.terminal_digest, terminal.terminal_digest);
            assert_eq!(acknowledgement.disposition, TerminalDisposition::Settled);
            socket.close(None).await.expect("paid provider close");
        });

        let response = reqwest::Client::new()
            .post(format!("http://{address}/v1/chat/completions"))
            .bearer_auth(CONSUMER_KEY)
            .header(header::CONTENT_TYPE, "application/json")
            .header("idempotency-key", "paid-axum-websocket")
            .body(
                r#"{"model":"darkbloom/pilot-text","messages":[{"role":"user","content":"paid"}],"stream":true,"max_completion_tokens":4}"#,
            )
            .send()
            .await
            .expect("paid consumer response");
        assert_eq!(response.status(), StatusCode::OK);
        let body = response.text().await.expect("paid response body");
        assert!(body.contains("\"content\":\"hello\""));
        provider.await.expect("paid provider task");

        let job: (String, i64, i64, String, String) = sqlx::query_as(
            r#"
            SELECT
                state,
                accepted_cumulative_tokens,
                usage_completion_tokens,
                consumer_key_hash,
                api_key_id
            FROM rust_coord.inference_jobs
            WHERE api_key_id = 'paid-key'
            "#,
        )
        .fetch_one(&pool)
        .await
        .expect("paid durable job");
        assert_eq!(job.0, "settled");
        assert_eq!((job.1, job.2), (1, 1));
        assert_eq!(job.3.len(), 64);
        assert_eq!(job.4, "paid-key");
        let balances: Vec<(String, i64, i64)> = sqlx::query_as(
            r#"
            SELECT account_id, balance_micro_usd, withdrawable_micro_usd
            FROM public.balances
            WHERE account_id IN ('consumer', 'provider', 'platform')
            ORDER BY account_id
            "#,
        )
        .fetch_all(&pool)
        .await
        .expect("paid balances");
        assert_eq!(
            balances,
            vec![
                ("consumer".to_owned(), 95, 95),
                ("platform".to_owned(), 2, 0),
                ("provider".to_owned(), 3, 3),
            ]
        );
        let projection: (i64, i64, i64, i64, i64, i64) = sqlx::query_as(
            r#"
            SELECT
                (SELECT COUNT(*) FROM rust_coord.financial_operations),
                (SELECT COUNT(*) FROM rust_coord.provider_terminals),
                (SELECT COUNT(*) FROM rust_coord.provider_terminals WHERE conflict),
                (SELECT COUNT(*) FROM public.usage),
                (SELECT COUNT(*) FROM public.provider_earnings),
                (SELECT COUNT(*) FROM rust_coord.outbox)
            "#,
        )
        .fetch_one(&pool)
        .await
        .expect("paid projections");
        assert_eq!(projection, (3, 1, 0, 1, 1, 1));
        let totals: (i64, i64, i64) = sqlx::query_as(
            "SELECT total_requests, total_prompt_tokens, total_completion_tokens FROM public.usage_totals WHERE id = 1",
        )
        .fetch_one(&pool)
        .await
        .expect("paid usage totals");
        assert_eq!(totals, (1, 3, 1));

        handle.shutdown();
        runtime_task
            .await
            .expect("paid runtime join")
            .expect("paid runtime shutdown");
        server.abort();
        let _ = server.await;
        pool.close().await;
        database
            .close(Duration::from_secs(2))
            .await
            .expect("close paid pilot database");
        ownership.release().await.expect("release paid ownership");
        let _ = std::fs::remove_dir_all(state_directory);
    })
    .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn sealed_stream_rejects_four_mib_separator_flood_and_restores_global_budget() {
    let _resource_load_guard = RESOURCE_LOAD_TEST_LOCK.lock().await;
    let (runtime, handle, state_directory) = test_runtime().await;
    let response_budget_baseline = handle.response_budget_available();
    let runtime_task = tokio::spawn(runtime.run());
    wait_ready(handle.clone()).await;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let address = listener.local_addr().expect("address");
    let server_handle = handle.clone();
    let server = tokio::spawn(async move {
        axum::serve(listener, routes(Some(server_handle)))
            .await
            .expect("serve");
    });

    let (mut socket, _) = connect_async(format!("ws://{address}/ws/provider"))
        .await
        .expect("websocket");
    let signing_key = SigningKey::generate();
    let _session = v2_handshake(
        &mut socket,
        &signing_key,
        ProviderProcessGenerationId::new([12; 16]),
    )
    .await;
    wait_inference_count(&handle, 1).await;

    let sender_private = [13_u8; 32];
    let plaintext = br#"{"model":"darkbloom/pilot-text","messages":[{"role":"user","content":"separator flood"}],"stream":true,"max_completion_tokens":4}"#;
    let payload = seal_box_with(
        &sender_private,
        &STANDARD
            .decode(PROCESS_PUBLIC)
            .expect("coordinator public")
            .try_into()
            .expect("32-byte key"),
        &[14; 24],
        plaintext,
    )
    .expect("sender seal");
    let envelope = darkbloom_coordinator_protocol::crypto::SenderSealEnvelope {
        kid: "test-process-key".to_owned(),
        ephemeral_public_key: payload.ephemeral_public_key,
        ciphertext: payload.ciphertext,
    };
    let consumer = tokio::spawn(async move {
        let response = reqwest::Client::new()
            .post(format!("http://{address}/v1/chat/completions"))
            .bearer_auth(CONSUMER_KEY)
            .header(header::CONTENT_TYPE, super::body::SEALED_CONTENT_TYPE)
            .json(&envelope)
            .send()
            .await;
        match response {
            Ok(response) => (Some(response.status()), response.bytes().await.is_err()),
            Err(_) => (None, true),
        }
    });

    let prepare = receive_prepare(&mut socket).await;
    let start = send_prepared_and_receive_start(&mut socket, &prepare).await;
    socket
        .send(Message::Text(
            serde_json::to_string(&ProviderControlMessage::StartAck(StartAck {
                identity: start.identity,
            }))
            .expect("StartAck JSON")
            .into(),
        ))
        .await
        .expect("StartAck");

    let separators = vec![b'\n'; 1024 * 1024];
    let mut rolling = [0_u8; 32];
    for sequence in 0..4_u64 {
        rolling = next_rolling_digest(rolling, sequence, 0, &separators);
        send_output_frame(
            &mut socket,
            &prepare,
            sequence,
            0,
            rolling,
            false,
            u8::try_from(sequence + 21).expect("nonce"),
            &separators,
        )
        .await;
    }

    let (status, body_failed) = consumer.await.expect("consumer task");
    assert!(
        status.is_none_or(|status| status == StatusCode::OK),
        "unexpected HTTP status before body rejection: {status:?}"
    );
    assert!(
        body_failed,
        "separator flood body must terminate with error"
    );
    assert_cancel_for(&mut socket, &prepare.identity).await;
    wait_active_request_count(&handle, 0).await;
    timeout(Duration::from_secs(2), async {
        while handle.response_budget_available() != response_budget_baseline {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("global response budget restored");
    assert_eq!(handle.inference_provider_count(), 1);
    assert!(handle.is_ready());

    socket.close(None).await.expect("provider close");
    handle.shutdown();
    runtime_task
        .await
        .expect("runtime join")
        .expect("runtime shutdown");
    server.abort();
    let _ = server.await;
    let _ = std::fs::remove_dir_all(state_directory);
}

fn spawn_stream_request(
    client: reqwest::Client,
    address: std::net::SocketAddr,
) -> tokio::task::JoinHandle<Result<reqwest::Response, reqwest::Error>> {
    tokio::spawn(async move {
        client
            .post(format!("http://{address}/v1/chat/completions"))
            .bearer_auth(CONSUMER_KEY)
            .header(header::CONTENT_TYPE, "application/json")
            .body(
                r#"{"model":"darkbloom/pilot-text","messages":[{"role":"user","content":"cancel"}],"stream":true,"max_completion_tokens":4}"#,
            )
            .send()
            .await
    })
}

async fn receive_prepare(socket: &mut TestWebSocket) -> Prepare {
    let message: CoordinatorControlMessage =
        serde_json::from_str(&next_text(socket).await).expect("Prepare JSON");
    let CoordinatorControlMessage::Prepare(prepare) = message else {
        panic!("expected Prepare");
    };
    prepare
}

async fn send_prepared(socket: &mut TestWebSocket, prepare: &Prepare) {
    socket
        .send(Message::Text(
            serde_json::to_string(&ProviderControlMessage::Prepared(Prepared {
                identity: prepare.identity.clone(),
                model: prepare.model.clone(),
                request_digest: prepare.request_digest,
                lease_ttl_ms: 5_000,
                prompt_tokens: 3,
                max_output_tokens: 4,
                engine_queue_depth: 0,
                reserved_kv_bytes: 2 * 1024 * 1024,
                reserved_media_bytes: 0,
                prefill_can_begin: true,
                estimated_prefill_ms: Some(1),
            }))
            .expect("Prepared JSON")
            .into(),
        ))
        .await
        .expect("Prepared");
}

async fn send_prepared_and_receive_start(socket: &mut TestWebSocket, prepare: &Prepare) -> Start {
    send_prepared(socket, prepare).await;
    let message: CoordinatorControlMessage =
        serde_json::from_str(&next_text(socket).await).expect("Start JSON");
    let CoordinatorControlMessage::Start(start) = message else {
        panic!("expected Start");
    };
    assert_eq!(start.identity, prepare.identity);
    start
}

#[allow(clippy::too_many_arguments)]
async fn send_output_frame(
    socket: &mut TestWebSocket,
    prepare: &Prepare,
    sequence: u64,
    cumulative_tokens: u64,
    rolling_digest: [u8; 32],
    final_frame: bool,
    nonce_byte: u8,
    plaintext: &[u8],
) {
    let provider_private: [u8; 32] = STANDARD
        .decode(PROCESS_PRIVATE)
        .expect("provider private")
        .try_into()
        .expect("32-byte key");
    let request_public: [u8; 32] = STANDARD
        .decode(&prepare.encrypted_body.ephemeral_public_key)
        .expect("request public")
        .try_into()
        .expect("32-byte key");
    let header = BinaryFrameHeader {
        kind: BinaryFrameKind::ResponseChunk,
        flags: if final_frame {
            BinaryFrameFlags::FINAL
        } else {
            BinaryFrameFlags::new(0).expect("empty flags")
        },
        minor: 0,
        provider_id: prepare.identity.provider_id,
        provider_process_generation: prepare.identity.provider_process_generation,
        session_epoch: prepare.identity.session_epoch,
        request_id: prepare.identity.request_id,
        attempt_id: prepare.identity.attempt_id,
        reservation_id: prepare.identity.reservation_id,
        lease_id: prepare.identity.lease_id,
        nonce: [nonce_byte; 24],
        rolling_digest,
        sequence,
        ciphertext_len: 0,
        cumulative_tokens,
    };
    let frame = seal_v2_frame(&provider_private, &request_public, header, plaintext)
        .expect("sealed response frame");
    socket
        .send(Message::Binary(frame.to_vec().into()))
        .await
        .expect("binary response");
}

async fn send_terminal(
    socket: &mut TestWebSocket,
    signing_key: &SigningKey,
    prepare: &Prepare,
    response_hash: Digest,
    rolling_digest: [u8; 32],
) {
    let mut terminal = ProviderTerminal {
        identity: prepare.identity.clone(),
        outcome: TerminalOutcome::Completed,
        error_class: None,
        prompt_tokens: 3,
        completion_tokens: 1,
        reasoning_tokens: 0,
        response_hash,
        final_generated_tokens: 1,
        rolling_digest: Digest::new(rolling_digest),
        model: prepare.model.clone(),
        terminal_digest: Digest::default(),
        signature: TerminalSignature::default(),
    };
    terminal.terminal_digest = terminal.computed_digest().expect("terminal digest");
    let signature: DerSignature = signing_key.sign(terminal.terminal_digest.as_bytes());
    terminal.signature = TerminalSignature::new(signature.as_bytes().to_vec());
    socket
        .send(Message::Text(
            serde_json::to_string(&ProviderControlMessage::Terminal(terminal))
                .expect("terminal JSON")
                .into(),
        ))
        .await
        .expect("terminal");
}

async fn assert_cancel_for(socket: &mut TestWebSocket, expected: &AttemptIdentity) {
    let message: CoordinatorControlMessage =
        serde_json::from_str(&next_text(socket).await).expect("Cancel JSON");
    let CoordinatorControlMessage::Cancel(cancel) = message else {
        panic!("expected Cancel, got {message:?}");
    };
    assert_eq!(&cancel.identity, expected);
}

async fn send_content_chunk(
    socket: &mut TestWebSocket,
    prepare: &Prepare,
    session: crate::provider::SessionIdentity,
) {
    assert!(session.matches_attempt(&prepare.identity));
    let provider_private: [u8; 32] = STANDARD
        .decode(PROCESS_PRIVATE)
        .expect("provider private")
        .try_into()
        .expect("32-byte key");
    let request_public: [u8; 32] = STANDARD
        .decode(&prepare.encrypted_body.ephemeral_public_key)
        .expect("request public")
        .try_into()
        .expect("32-byte key");
    let chunk = br#"data: {"id":"chatcmpl-cancel","object":"chat.completion.chunk","created":1,"model":"darkbloom/pilot-text","choices":[{"index":0,"delta":{"content":"hello"},"finish_reason":null}]}

"#;
    let rolling = next_rolling_digest([0; 32], 0, 1, chunk);
    let header = BinaryFrameHeader {
        kind: BinaryFrameKind::ResponseChunk,
        flags: BinaryFrameFlags::new(0).expect("empty flags"),
        minor: 0,
        provider_id: prepare.identity.provider_id,
        provider_process_generation: prepare.identity.provider_process_generation,
        session_epoch: prepare.identity.session_epoch,
        request_id: prepare.identity.request_id,
        attempt_id: prepare.identity.attempt_id,
        reservation_id: prepare.identity.reservation_id,
        lease_id: prepare.identity.lease_id,
        nonce: [0x41; 24],
        rolling_digest: rolling,
        sequence: 0,
        ciphertext_len: 0,
        cumulative_tokens: 1,
    };
    let frame =
        seal_v2_frame(&provider_private, &request_public, header, chunk).expect("sealed chunk");
    socket
        .send(Message::Binary(frame.to_vec().into()))
        .await
        .expect("binary chunk");
}

async fn v2_handshake(
    socket: &mut TestWebSocket,
    signing_key: &SigningKey,
    generation: ProviderProcessGenerationId,
) -> crate::provider::SessionIdentity {
    v2_handshake_with_token(socket, signing_key, generation, PROVIDER_TOKEN).await
}

async fn v2_handshake_with_token(
    socket: &mut TestWebSocket,
    signing_key: &SigningKey,
    generation: ProviderProcessGenerationId,
    provider_token: &str,
) -> crate::provider::SessionIdentity {
    socket
        .send(Message::Text(
            registration_wire_v2_with_token(signing_key, generation, provider_token).into(),
        ))
        .await
        .expect("v2 registration");
    let challenge: CoordinatorMessage =
        serde_json::from_str(&next_text(socket).await).expect("challenge JSON");
    let CoordinatorMessage::AttestationChallenge(challenge) = challenge else {
        panic!("expected attestation challenge");
    };
    socket
        .send(Message::Text(
            serde_json::to_string(&ProviderMessage::AttestationResponse(challenge_response(
                signing_key,
                &challenge.nonce,
                &challenge.timestamp,
            )))
            .expect("challenge response JSON")
            .into(),
        ))
        .await
        .expect("challenge response");
    let acknowledgement: RegistrationResponse =
        serde_json::from_str(&next_text(socket).await).expect("register ACK");
    let RegistrationResponse::RegisterAck(acknowledgement) = acknowledgement;
    assert_eq!(
        acknowledgement
            .protocol_capabilities
            .as_ref()
            .map(|capabilities| capabilities.protocol_major),
        Some(2)
    );
    crate::provider::SessionIdentity {
        provider_id: acknowledgement.provider_id,
        provider_process_generation: acknowledgement.provider_process_generation,
        session_epoch: acknowledgement.session_epoch,
    }
}

async fn serve_v2_request(
    socket: &mut TestWebSocket,
    signing_key: &SigningKey,
    session: crate::provider::SessionIdentity,
    request_number: u8,
) {
    let prepare = receive_prepare(socket).await;
    let _ =
        serve_v2_request_from_prepare(socket, signing_key, session, request_number, prepare).await;
}

async fn serve_v2_request_from_prepare(
    socket: &mut TestWebSocket,
    signing_key: &SigningKey,
    session: crate::provider::SessionIdentity,
    request_number: u8,
    prepare: Prepare,
) -> ProviderTerminal {
    serve_v2_request_from_prepare_with_ack(
        socket,
        signing_key,
        session,
        request_number,
        prepare,
        true,
    )
    .await
}

async fn serve_v2_request_from_prepare_with_ack(
    socket: &mut TestWebSocket,
    signing_key: &SigningKey,
    session: crate::provider::SessionIdentity,
    request_number: u8,
    prepare: Prepare,
    await_terminal_ack: bool,
) -> ProviderTerminal {
    assert_eq!(prepare.identity.provider_id, session.provider_id);
    assert_eq!(
        prepare.identity.provider_process_generation,
        session.provider_process_generation
    );
    assert_eq!(prepare.identity.session_epoch, session.session_epoch);
    let provider_private: [u8; 32] = STANDARD
        .decode(PROCESS_PRIVATE)
        .expect("provider private")
        .try_into()
        .expect("32-byte key");
    let plaintext =
        open_box(&provider_private, &prepare.encrypted_body).expect("open provider request");
    let request: serde_json::Value = serde_json::from_slice(&plaintext).expect("request JSON");
    assert_eq!(request["model"], "darkbloom/pilot-text");

    let prompt_tokens = 3;
    socket
        .send(Message::Text(
            serde_json::to_string(&ProviderControlMessage::Prepared(Prepared {
                identity: prepare.identity.clone(),
                model: prepare.model.clone(),
                request_digest: prepare.request_digest,
                lease_ttl_ms: 5_000,
                prompt_tokens,
                max_output_tokens: 4,
                engine_queue_depth: 0,
                reserved_kv_bytes: 2 * 1024 * 1024,
                reserved_media_bytes: 0,
                prefill_can_begin: true,
                estimated_prefill_ms: Some(1),
            }))
            .expect("Prepared JSON")
            .into(),
        ))
        .await
        .expect("Prepared");
    let start: CoordinatorControlMessage =
        serde_json::from_str(&next_text(socket).await).expect("Start JSON");
    let CoordinatorControlMessage::Start(start) = start else {
        panic!("expected Start");
    };
    assert_eq!(start.identity, prepare.identity);
    socket
        .send(Message::Text(
            serde_json::to_string(&ProviderControlMessage::StartAck(StartAck {
                identity: prepare.identity.clone(),
            }))
            .expect("StartAck JSON")
            .into(),
        ))
        .await
        .expect("StartAck");

    let request_public: [u8; 32] = STANDARD
        .decode(&prepare.encrypted_body.ephemeral_public_key)
        .expect("request public")
        .try_into()
        .expect("32-byte key");
    let role = br#"data: {"id":"chatcmpl-pilot","object":"chat.completion.chunk","created":1,"model":"darkbloom/pilot-text","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

"#;
    let content = br#"data: {"id":"chatcmpl-pilot","object":"chat.completion.chunk","created":1,"model":"darkbloom/pilot-text","choices":[{"index":0,"delta":{"content":"hello"},"finish_reason":"stop"}]}

"#;
    let done = b"data: [DONE]\n\n".as_slice();
    let chunks = if request_number == 2 {
        let role_split = role.len() - 1;
        let content_split = content.len() / 2;
        vec![
            &role[..role_split],
            &role[role_split..],
            &content[..content_split],
            &content[content_split..],
            done,
        ]
    } else {
        vec![role.as_slice(), content.as_slice(), done]
    };
    let mut rolling = [0_u8; 32];
    let mut response_hasher = Sha256::new();
    for (sequence, chunk) in chunks.iter().enumerate() {
        let cumulative_tokens = u64::from(sequence + 1 == chunks.len());
        rolling = next_rolling_digest(
            rolling,
            u64::try_from(sequence).expect("sequence"),
            cumulative_tokens,
            chunk,
        );
        response_hasher.update(chunk);
        let header = BinaryFrameHeader {
            kind: BinaryFrameKind::ResponseChunk,
            flags: if sequence + 1 == chunks.len() {
                BinaryFrameFlags::FINAL
            } else {
                BinaryFrameFlags::new(0).expect("empty flags")
            },
            minor: 0,
            provider_id: prepare.identity.provider_id,
            provider_process_generation: prepare.identity.provider_process_generation,
            session_epoch: prepare.identity.session_epoch,
            request_id: prepare.identity.request_id,
            attempt_id: prepare.identity.attempt_id,
            reservation_id: prepare.identity.reservation_id,
            lease_id: prepare.identity.lease_id,
            nonce: [request_number
                .saturating_add(sequence as u8)
                .saturating_add(1); 24],
            rolling_digest: rolling,
            sequence: u64::try_from(sequence).expect("sequence"),
            ciphertext_len: 0,
            cumulative_tokens,
        };
        let frame = seal_v2_frame(&provider_private, &request_public, header, chunk)
            .expect("seal response frame");
        socket
            .send(Message::Binary(frame.to_vec().into()))
            .await
            .expect("binary response");
    }

    let mut terminal = ProviderTerminal {
        identity: prepare.identity,
        outcome: TerminalOutcome::Completed,
        error_class: None,
        prompt_tokens,
        completion_tokens: 1,
        reasoning_tokens: 0,
        response_hash: Digest::new(response_hasher.finalize().into()),
        final_generated_tokens: 1,
        rolling_digest: Digest::new(rolling),
        model: prepare.model,
        terminal_digest: Digest::default(),
        signature: TerminalSignature::default(),
    };
    terminal.terminal_digest = terminal.computed_digest().expect("terminal digest");
    let signature: DerSignature = signing_key.sign(terminal.terminal_digest.as_bytes());
    terminal.signature = TerminalSignature::new(signature.as_bytes().to_vec());
    socket
        .send(Message::Text(
            serde_json::to_string(&ProviderControlMessage::Terminal(terminal.clone()))
                .expect("terminal JSON")
                .into(),
        ))
        .await
        .expect("terminal");
    if await_terminal_ack {
        let acknowledgement: CoordinatorControlMessage =
            serde_json::from_str(&next_text(socket).await).expect("terminal ACK JSON");
        assert!(matches!(
            acknowledgement,
            CoordinatorControlMessage::TerminalAck(_)
        ));
    }
    terminal
}

fn open_sealed_sse(bytes: &[u8], sender_private: &[u8; 32]) -> Vec<u8> {
    let text = std::str::from_utf8(bytes).expect("sealed SSE UTF-8");
    let mut opened = Vec::new();
    for event in text.split("\n\n").filter(|event| !event.is_empty()) {
        let ciphertext = event.strip_prefix("data: ").expect("sealed data field");
        let plaintext = open_box(
            sender_private,
            &EncryptedPayload {
                ephemeral_public_key: PROCESS_PUBLIC.to_owned(),
                ciphertext: ciphertext.to_owned(),
            },
        )
        .expect("open sealed SSE event");
        opened.extend_from_slice(&plaintext);
        opened.extend_from_slice(b"\n\n");
    }
    opened
}

fn signed_historical_terminal(
    signing_key: &SigningKey,
    session: crate::provider::SessionIdentity,
) -> ProviderTerminal {
    signed_unrouted_terminal(signing_key, session, 0x32)
}

fn signed_unrouted_terminal(
    signing_key: &SigningKey,
    session: crate::provider::SessionIdentity,
    marker: u8,
) -> ProviderTerminal {
    let mut terminal = ProviderTerminal {
        identity: AttemptIdentity {
            provider_id: session.provider_id,
            provider_process_generation: session.provider_process_generation,
            session_epoch: session.session_epoch,
            request_id: RequestId::new([marker.saturating_add(1); 16]),
            attempt_id: AttemptId::new([marker.saturating_add(2); 16]),
            reservation_id: ReservationId::new([marker.saturating_add(3); 16]),
            lease_id: LeaseId::new([marker.saturating_add(4); 16]),
        },
        outcome: TerminalOutcome::Completed,
        error_class: None,
        prompt_tokens: 1,
        completion_tokens: 1,
        reasoning_tokens: 0,
        response_hash: Digest::new([0x35; 32]),
        final_generated_tokens: 1,
        rolling_digest: Digest::new([0x36; 32]),
        model: "darkbloom/pilot-text".to_owned(),
        terminal_digest: Digest::default(),
        signature: TerminalSignature::default(),
    };
    terminal.terminal_digest = terminal.computed_digest().expect("terminal digest");
    let signature: DerSignature = signing_key.sign(terminal.terminal_digest.as_bytes());
    terminal.signature = TerminalSignature::new(signature.as_bytes().to_vec());
    terminal
}

async fn test_runtime() -> (PilotRuntime, crate::pilot::PilotHandle, PathBuf) {
    let config = test_config();
    let state_directory = config.state_directory.clone();
    let (runtime, handle) = PilotRuntime::build(&config).await.expect("pilot runtime");
    (runtime, handle, state_directory)
}

fn test_config() -> PilotConfig {
    let mut config = PilotConfig::disabled();
    config.enabled = true;
    let state_directory =
        std::env::temp_dir().join(format!("darkbloom-pilot-http-{}", Uuid::new_v4()));
    config.state_directory = state_directory;
    config.provider_credentials = Arc::from([(
        darkbloom_coordinator_protocol::v2::ProviderId::new([1; 16]),
        Arc::from(PROVIDER_TOKEN),
    )]);
    config.consumer_credentials = Arc::from([crate::pilot::ConsumerCredentialEntry {
        raw_key: Arc::from(CONSUMER_KEY),
        account_id: None,
        api_key_id: Arc::from("self-route"),
    }]);
    config.process_key_id = Arc::from("test-process-key");
    config.process_private_key = Arc::from(PROCESS_PRIVATE);
    config.process_public_key = Arc::from(PROCESS_PUBLIC);
    config
}

async fn wait_ready(mut handle: crate::pilot::PilotHandle) {
    timeout(Duration::from_secs(2), async {
        while !handle.is_ready() {
            handle.changed().await.expect("readiness change");
        }
    })
    .await
    .expect("runtime ready");
}

async fn wait_inference_count(handle: &crate::pilot::PilotHandle, expected: usize) {
    let result = timeout(Duration::from_secs(2), async {
        while handle.inference_provider_count() != expected {
            tokio::task::yield_now().await;
        }
    })
    .await;
    assert!(
        result.is_ok(),
        "inference provider count: expected {expected}, actual {}",
        handle.inference_provider_count()
    );
}

async fn wait_visible_count(handle: &crate::pilot::PilotHandle, expected: usize) {
    timeout(Duration::from_secs(2), async {
        while handle.visible_provider_count() != expected {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("visible provider count");
}

async fn wait_active_request_count(handle: &crate::pilot::PilotHandle, expected: usize) {
    timeout(Duration::from_secs(2), async {
        while handle.active_request_count() != expected {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("active request count");
}

fn descriptor_count() -> usize {
    std::fs::read_dir("/proc/self/fd")
        .expect("process descriptor directory")
        .count()
}

async fn stable_descriptor_count() -> usize {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(1);
    let mut observed = descriptor_count();
    let mut unchanged = 0_u8;
    loop {
        tokio::time::sleep(Duration::from_millis(10)).await;
        let current = descriptor_count();
        if current == observed {
            unchanged = unchanged.saturating_add(1);
            if unchanged == 10 || tokio::time::Instant::now() >= deadline {
                return current;
            }
        } else {
            observed = current;
            unchanged = 0;
        }
    }
}

async fn wait_descriptor_count_at_most(maximum: usize) {
    timeout(Duration::from_secs(2), async {
        while descriptor_count() > maximum {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap_or_else(|_| {
        panic!(
            "process descriptor count {} did not return to bound {maximum}",
            descriptor_count()
        )
    });
}

fn authorized_request(uri: &str, body: Body) -> Request<Body> {
    Request::builder()
        .uri(uri)
        .header(header::AUTHORIZATION, format!("Bearer {CONSUMER_KEY}"))
        .body(body)
        .expect("request")
}

fn sign(key: &SigningKey, bytes: &[u8]) -> String {
    let signature: DerSignature = key.sign(bytes);
    STANDARD.encode(signature.as_bytes())
}

fn registration_wire(key: &SigningKey) -> String {
    let public_key = STANDARD.encode(key.verifying_key().to_sec1_point(false));
    let blob = format!(
        concat!(
            r#"{{"encryptionPublicKey":"{PROCESS_PUBLIC}","publicKey":"{public_key}","#,
            r#""secureBootEnabled":true,"secureEnclaveAvailable":true,"#,
            r#""sipEnabled":true,"timestamp":"2026-07-11T00:00:00Z"}}"#
        ),
        PROCESS_PUBLIC = PROCESS_PUBLIC,
        public_key = public_key,
    );
    let attestation = format!(
        r#"{{"attestation":{blob},"signature":"{}"}}"#,
        sign(key, blob.as_bytes())
    );
    format!(
        concat!(
            r#"{{"type":"register","hardware":{{"machine_model":"Mac","#,
            r#""chip_name":"M","chip_family":"M","chip_tier":"base","memory_gb":16,"#,
            r#""memory_available_gb":8,"cpu_cores":{{"total":8,"performance":4,"efficiency":4}},"#,
            r#""gpu_cores":8,"memory_bandwidth_gbs":100}},"models":[{{"#,
            r#""id":"darkbloom/pilot-text","size_bytes":1,"template_render_ok":true}}],"#,
            r#""backend":"mlx","version":"test","public_key":"{PROCESS_PUBLIC}","#,
            r#""encrypted_response_chunks":true,"attestation":{attestation},"#,
            r#""auth_token":"{PROVIDER_TOKEN}","private_only":true}}"#
        ),
        PROCESS_PUBLIC = PROCESS_PUBLIC,
        attestation = attestation,
        PROVIDER_TOKEN = PROVIDER_TOKEN,
    )
}

fn registration_wire_v2_with_token(
    key: &SigningKey,
    generation: ProviderProcessGenerationId,
    provider_token: &str,
) -> String {
    let public_key = STANDARD.encode(key.verifying_key().to_sec1_point(false));
    let blob = format!(
        concat!(
            r#"{{"encryptionPublicKey":"{PROCESS_PUBLIC}","publicKey":"{public_key}","#,
            r#""secureBootEnabled":true,"secureEnclaveAvailable":true,"#,
            r#""sipEnabled":true,"timestamp":"2026-07-11T00:00:00Z"}}"#
        ),
        PROCESS_PUBLIC = PROCESS_PUBLIC,
        public_key = public_key,
    );
    let attestation = format!(
        r#"{{"attestation":{blob},"signature":"{}"}}"#,
        sign(key, blob.as_bytes())
    );
    format!(
        concat!(
            r#"{{"type":"register","hardware":{{"machine_model":"Mac","#,
            r#""chip_name":"M","chip_family":"M","chip_tier":"base","memory_gb":16,"#,
            r#""memory_available_gb":8,"cpu_cores":{{"total":8,"performance":4,"efficiency":4}},"#,
            r#""gpu_cores":8,"memory_bandwidth_gbs":100}},"models":[{{"#,
            r#""id":"darkbloom/pilot-text","size_bytes":1,"template_render_ok":true}}],"#,
            r#""backend":"mlx","version":"test-v2","public_key":"{PROCESS_PUBLIC}","#,
            r#""encrypted_response_chunks":true,"attestation":{attestation},"#,
            r#""auth_token":"{provider_token}","private_only":true,"#,
            r#""provider_process_generation":"{generation}","protocol_capabilities":{{"#,
            r#""protocol_major":2,"protocol_minor":0,"prepared_leases":true,"#,
            r#""start_authorization":true,"structured_errors":true,"start_ack":true,"#,
            r#""abort_ack":true,"cancel_ack":true,"durable_terminals":true,"#,
            r#""model_lifecycle_events":true,"binary_payload_frames":true,"#,
            r#""coordinator_replay_fences":true,"attempt_reconciliation":true}}}}"#
        ),
        PROCESS_PUBLIC = PROCESS_PUBLIC,
        attestation = attestation,
        provider_token = provider_token,
        generation = generation,
    )
}

fn challenge_response(key: &SigningKey, nonce: &str, timestamp: &str) -> AttestationResponse {
    let mut response = AttestationResponse {
        nonce: nonce.to_owned(),
        signature: sign(key, format!("{nonce}{timestamp}").as_bytes()),
        status_signature: String::new(),
        public_key: PROCESS_PUBLIC.to_owned(),
        hypervisor_active: None,
        rdma_disabled: Some(true),
        sip_enabled: Some(true),
        secure_boot_enabled: Some(true),
        binary_hash: "binary".to_owned(),
        active_model_hash: String::new(),
        python_hash: String::new(),
        runtime_hash: String::new(),
        template_hashes: BTreeMap::new(),
        grpc_binary_hash: String::new(),
        model_hashes: BTreeMap::new(),
    };
    response.status_signature = sign(
        key,
        &response
            .canonical_status_bytes(timestamp)
            .expect("canonical status"),
    );
    response
}

async fn next_text(
    socket: &mut tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
) -> String {
    match timeout(WEBSOCKET_RECEIVE_TIMEOUT, socket.next())
        .await
        .expect("websocket receive timeout")
        .expect("websocket open")
        .expect("websocket message")
    {
        Message::Text(text) => text.to_string(),
        other => panic!("expected text message, got {other:?}"),
    }
}
