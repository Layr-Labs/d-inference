use std::{
    collections::BTreeMap,
    net::SocketAddr,
    sync::{
        Arc,
        atomic::{AtomicU64, AtomicUsize, Ordering},
    },
    time::Duration,
};

use axum::{
    Json, Router,
    extract::{ConnectInfo, State},
    http::{HeaderMap, StatusCode, header},
    response::IntoResponse,
    routing::{get, post},
};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use darkbloom_coordinator_protocol::{
    crypto::{decode_array, seal_box_with, seal_v2_frame},
    v1::{
        AttestationResponse, CoordinatorMessage, EncryptedPayload, InferenceAccepted,
        InferenceComplete, InferenceResponseChunk, ProviderMessage, UsageInfo,
    },
    v2::{
        AbortAck, AttemptStatus, AttemptStatusState, BinaryFrameFlags, BinaryFrameHeader,
        BinaryFrameKind, CancelAck, CoordinatorControlMessage, Digest, Prepare, Prepared,
        ProviderControlMessage, ProviderProcessGenerationId, ProviderTerminal,
        RegistrationResponse, ReplayFenceAck, StartAck, TerminalOutcome, TerminalSignature,
    },
};
use darkbloom_coordinator_server::request::next_rolling_digest;
use futures_util::{SinkExt as _, StreamExt as _};
use p256::{
    ecdsa::{DerSignature, SigningKey, signature::Signer as _},
    elliptic_curve::Generate as _,
};
use serde::Deserialize;
use sha2::{Digest as _, Sha256};
use subtle::ConstantTimeEq as _;
use tokio::{sync::watch, task::JoinSet, time::sleep};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async, tungstenite::Message};

const PROCESS_PRIVATE: &str = "XasIfmJKikt54X+Lg4AO5m87sSkmGLb9HC+LJ/+I4Os=";
const PROCESS_PUBLIC: &str = "3p7bfXt9wbTTW2HC7OQ1Nz+DQ8hbeGdNrfx+FG+IK08=";

type Error = Box<dyn std::error::Error + Send + Sync>;
type Socket = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Target {
    Go,
    Rust,
}

#[derive(Clone)]
struct Config {
    target: Target,
    websocket_url: String,
    control_address: SocketAddr,
    control_token: Arc<str>,
    provider_token: Arc<str>,
    model: Arc<str>,
    sessions: usize,
    chunk_multiplier: usize,
}

#[derive(Clone)]
struct PeerState {
    expected_sessions: usize,
    connected: Arc<AtomicUsize>,
    served_requests: Arc<AtomicU64>,
    emitted_chunks: Arc<AtomicU64>,
    replacement_count: Arc<AtomicU64>,
    sent_unknown_disconnects: Arc<AtomicU64>,
    sent_unknown_armed: Arc<AtomicUsize>,
    hedge_count: Arc<AtomicU64>,
    hedge_delays: Arc<AtomicUsize>,
    replacement_pending: Arc<AtomicUsize>,
    generation: watch::Sender<u64>,
    control_token: Arc<str>,
}

#[derive(Deserialize)]
struct Directive {
    directive: String,
    chunk_multiplier: usize,
}

#[tokio::main]
async fn main() -> Result<(), Error> {
    let config = Config::from_env()?;
    let (generation, _) = watch::channel(0);
    let state = PeerState {
        expected_sessions: config.sessions,
        connected: Arc::new(AtomicUsize::new(0)),
        served_requests: Arc::new(AtomicU64::new(0)),
        emitted_chunks: Arc::new(AtomicU64::new(0)),
        replacement_count: Arc::new(AtomicU64::new(0)),
        sent_unknown_disconnects: Arc::new(AtomicU64::new(0)),
        sent_unknown_armed: Arc::new(AtomicUsize::new(0)),
        hedge_count: Arc::new(AtomicU64::new(0)),
        hedge_delays: Arc::new(AtomicUsize::new(0)),
        replacement_pending: Arc::new(AtomicUsize::new(0)),
        generation,
        control_token: config.control_token.clone(),
    };
    let listener = tokio::net::TcpListener::bind(config.control_address).await?;
    let control_state = state.clone();
    let control = tokio::spawn(async move {
        axum::serve(
            listener,
            control_router(control_state).into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await
    });

    let signing_key = SigningKey::generate();
    let mut sessions = JoinSet::new();
    for index in 0..config.sessions {
        sessions.spawn(run_session(
            index,
            config.clone(),
            state.clone(),
            signing_key.clone(),
        ));
        // Rust persists provider activation state through a deliberately
        // serialized barrier. Keep the 1,000 connections real and long-lived,
        // but avoid manufacturing activation timeouts by putting every
        // registration on that barrier at the same instant.
        if index + 1 < config.sessions {
            sleep(Duration::from_millis(100)).await;
        }
    }
    tokio::select! {
        result = control => result??,
        joined = sessions.join_next() => {
            match joined {
                Some(result) => result??,
                None => return Err("pilot peer started no sessions".into()),
            }
        }
        _ = shutdown_signal() => {}
    }
    sessions.shutdown().await;
    Ok(())
}

impl Config {
    fn from_env() -> Result<Self, Error> {
        let target = match required("PILOT_TARGET")?.as_str() {
            "go" => Target::Go,
            "rust" => Target::Rust,
            other => return Err(format!("PILOT_TARGET must be go or rust, got {other:?}").into()),
        };
        let coordinator =
            parse_coordinator_url(&required("PILOT_COORDINATOR_URL")?).map_err(Error::from)?;
        let mut websocket = coordinator;
        websocket
            .set_scheme("ws")
            .map_err(|_| "invalid WebSocket scheme")?;
        websocket.set_path("/ws/provider");
        websocket.set_query(None);
        websocket.set_fragment(None);
        let control_address = required("PILOT_CONTROL_ADDRESS")?.parse::<SocketAddr>()?;
        if !control_address.ip().is_loopback() {
            return Err("PILOT_CONTROL_ADDRESS must be loopback".into());
        }
        let control_token = required("PILOT_CONTROL_TOKEN")?;
        if control_token.len() < 32 {
            return Err("PILOT_CONTROL_TOKEN must contain at least 32 characters".into());
        }
        let sessions = parse_positive("PILOT_WEBSOCKET_SESSIONS")?;
        let chunk_multiplier = parse_positive("PILOT_CHUNK_MULTIPLIER")?;
        Ok(Self {
            target,
            websocket_url: websocket.to_string(),
            control_address,
            control_token: Arc::from(control_token),
            provider_token: Arc::from(required("PILOT_PROVIDER_TOKEN")?),
            model: Arc::from(required("PILOT_MODEL")?),
            sessions,
            chunk_multiplier,
        })
    }
}

fn parse_coordinator_url(value: &str) -> Result<url::Url, &'static str> {
    let coordinator =
        url::Url::parse(value).map_err(|_| "PILOT_COORDINATOR_URL must be a valid URL")?;
    if coordinator.scheme() != "http"
        || !matches!(
            coordinator.host_str(),
            Some("localhost" | "127.0.0.1" | "::1" | "[::1]")
        )
        || coordinator.port().is_none()
        || !coordinator.username().is_empty()
        || coordinator.password().is_some()
        || coordinator.query().is_some()
        || coordinator.fragment().is_some()
        || !matches!(coordinator.path(), "" | "/")
    {
        return Err("PILOT_COORDINATOR_URL must be explicit localhost, 127.0.0.1, or ::1 HTTP");
    }
    Ok(coordinator)
}

fn control_router(state: PeerState) -> Router {
    Router::new()
        .route("/health", get(peer_health))
        .route("/control", post(peer_control))
        .route("/counters", get(peer_counters))
        .with_state(state)
}

async fn peer_health(State(state): State<PeerState>) -> impl IntoResponse {
    let connected = state.connected.load(Ordering::Acquire);
    Json(serde_json::json!({
        "status": if connected == state.expected_sessions { "ok" } else { "starting" },
        "connected_sessions": connected,
        "expected_sessions": state.expected_sessions,
    }))
}

async fn peer_control(
    State(state): State<PeerState>,
    ConnectInfo(remote): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(directive): Json<Directive>,
) -> impl IntoResponse {
    if !authorized(&state, remote, &headers) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(serde_json::json!({"applied": false})),
        );
    }
    if directive.chunk_multiplier == 0 {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"applied": false, "error": "zero chunk multiplier"})),
        );
    }
    match directive.directive.as_str() {
        "session_replacement" => {
            let completed = state.replacement_count.load(Ordering::Acquire) + 1;
            state.replacement_pending.fetch_add(1, Ordering::AcqRel);
            let next = *state.generation.borrow() + 1;
            state.generation.send_replace(next);
            for _ in 0..500 {
                if state.replacement_count.load(Ordering::Acquire) >= completed
                    && state.connected.load(Ordering::Acquire) == state.expected_sessions
                {
                    break;
                }
                sleep(Duration::from_millis(20)).await;
            }
            if state.replacement_count.load(Ordering::Acquire) < completed
                || state.connected.load(Ordering::Acquire) != state.expected_sessions
            {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(serde_json::json!({
                        "applied": false,
                        "error": "session replacement did not become ready",
                    })),
                );
            }
        }
        "sent_unknown" => {
            state.sent_unknown_armed.fetch_add(1, Ordering::AcqRel);
        }
        "hedge" => {
            state.hedge_delays.fetch_add(1, Ordering::AcqRel);
        }
        _ => {
            return (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"applied": false, "error": "unknown directive"})),
            );
        }
    }
    (
        StatusCode::OK,
        Json(serde_json::json!({
            "applied": true,
            "directive": directive.directive,
            "connected_sessions": state.connected.load(Ordering::Acquire),
        })),
    )
}

async fn peer_counters(
    State(state): State<PeerState>,
    ConnectInfo(remote): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
) -> impl IntoResponse {
    if !authorized(&state, remote, &headers) {
        return (StatusCode::UNAUTHORIZED, Json(serde_json::json!({})));
    }
    (
        StatusCode::OK,
        Json(serde_json::json!({
            "connected_sessions": state.connected.load(Ordering::Acquire),
            "expected_sessions": state.expected_sessions,
            "served_requests": state.served_requests.load(Ordering::Acquire),
            "emitted_chunks": state.emitted_chunks.load(Ordering::Acquire),
            "session_replacements": state.replacement_count.load(Ordering::Acquire),
            "hedges": state.hedge_count.load(Ordering::Acquire),
            "sent_unknown_disconnects": state.sent_unknown_disconnects.load(Ordering::Acquire),
        })),
    )
}

fn authorized(state: &PeerState, remote: SocketAddr, headers: &HeaderMap) -> bool {
    if !remote.ip().is_loopback() {
        return false;
    }
    let presented = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .unwrap_or_default();
    presented.len() == state.control_token.len()
        && bool::from(presented.as_bytes().ct_eq(state.control_token.as_bytes()))
}

async fn run_session(
    index: usize,
    config: Config,
    state: PeerState,
    signing_key: SigningKey,
) -> Result<(), Error> {
    let mut generation = state.generation.subscribe();
    loop {
        match connect_and_serve(index, &config, &state, &signing_key, &mut generation).await {
            Ok(()) => {}
            Err(error) => eprintln!("pilot peer session {index} reconnecting: {error}"),
        }
        sleep(Duration::from_millis(100)).await;
    }
}

async fn connect_and_serve(
    index: usize,
    config: &Config,
    state: &PeerState,
    signing_key: &SigningKey,
    generation: &mut watch::Receiver<u64>,
) -> Result<(), Error> {
    let (mut socket, _) = connect_async(&config.websocket_url).await?;
    let process_generation =
        ProviderProcessGenerationId::new((u128::try_from(index)? + 10_000).to_be_bytes());
    let token = format!("{}-{index:06}", config.provider_token);
    socket
        .send(Message::Text(
            registration_wire(
                signing_key,
                process_generation,
                config.target == Target::Rust,
                if config.target == Target::Rust {
                    &token
                } else {
                    ""
                },
                &config.model,
            )
            .into(),
        ))
        .await?;
    loop {
        let message = tokio::select! {
            changed = generation.changed(), if index == 0 => {
                changed?;
                let _ = socket.close(None).await;
                return Ok(());
            }
            message = socket.next() => message.ok_or("coordinator closed peer socket")??,
        };
        let Message::Text(text) = message else {
            continue;
        };
        let value: serde_json::Value = serde_json::from_str(&text)?;
        match value.get("type").and_then(serde_json::Value::as_str) {
            Some("attestation_challenge") => {
                let challenge: CoordinatorMessage = serde_json::from_value(value)?;
                let CoordinatorMessage::AttestationChallenge(challenge) = challenge else {
                    unreachable!()
                };
                let response =
                    challenge_response(signing_key, &challenge.nonce, &challenge.timestamp)?;
                send_json(&mut socket, &ProviderMessage::AttestationResponse(response)).await?;
                if config.target == Target::Go {
                    socket
                        .send(Message::Text(heartbeat_wire(&config.model).into()))
                        .await?;
                    record_replacement_if_pending(state, index);
                    state.connected.fetch_add(1, Ordering::AcqRel);
                    let result =
                        serve_go(&mut socket, config, state, index, generation, signing_key).await;
                    state.connected.fetch_sub(1, Ordering::AcqRel);
                    return result;
                }
            }
            Some("register_ack") => {
                let acknowledgement: RegistrationResponse = serde_json::from_value(value)?;
                let RegistrationResponse::RegisterAck(acknowledgement) = acknowledgement;
                if acknowledgement.provider_process_generation != process_generation
                    || acknowledgement.session_epoch.0 == 0
                {
                    return Err("Rust register ACK identity mismatch".into());
                }
                socket
                    .send(Message::Text(heartbeat_wire(&config.model).into()))
                    .await?;
                record_replacement_if_pending(state, index);
                state.connected.fetch_add(1, Ordering::AcqRel);
                let result =
                    serve_rust(&mut socket, config, state, index, generation, signing_key).await;
                state.connected.fetch_sub(1, Ordering::AcqRel);
                return result;
            }
            _ => {}
        }
    }
}

async fn serve_go(
    socket: &mut Socket,
    config: &Config,
    state: &PeerState,
    index: usize,
    generation: &mut watch::Receiver<u64>,
    signing_key: &SigningKey,
) -> Result<(), Error> {
    loop {
        let message = tokio::select! {
            changed = generation.changed(), if index == 0 => {
                changed?;
                let _ = socket.close(None).await;
                return Ok(());
            }
            _ = sleep(Duration::from_secs(10)) => {
                socket.send(Message::Text(heartbeat_wire(&config.model).into())).await?;
                continue;
            }
            message = socket.next() => message.ok_or("Go coordinator closed peer socket")??,
        };
        let Message::Text(text) = message else {
            continue;
        };
        let message: CoordinatorMessage = serde_json::from_str(&text)?;
        match message {
            CoordinatorMessage::InferenceRequest(request) => {
                if consume_one(&state.sent_unknown_armed) {
                    state
                        .sent_unknown_disconnects
                        .fetch_add(1, Ordering::AcqRel);
                    socket.close(None).await?;
                    return Ok(());
                }
                apply_hedge_delay(state).await;
                send_json(
                    socket,
                    &ProviderMessage::InferenceAccepted(InferenceAccepted {
                        request_id: request.request_id.clone(),
                    }),
                )
                .await?;
                let payload = request
                    .encrypted_body
                    .as_ref()
                    .ok_or("Go inference request was not encrypted")?;
                let recipient =
                    decode_array::<32>("ephemeral_public_key", &payload.ephemeral_public_key)?;
                let chunks = response_chunks(config.chunk_multiplier, &config.model);
                let provider_private = provider_private()?;
                let mut response_hasher = Sha256::new();
                for (sequence, chunk) in chunks.iter().enumerate() {
                    response_hasher.update(chunk);
                    let nonce = unique_nonce(
                        index,
                        state.served_requests.load(Ordering::Acquire),
                        sequence,
                    );
                    let encrypted = seal_box_with(&provider_private, &recipient, &nonce, chunk)?;
                    send_json(
                        socket,
                        &ProviderMessage::InferenceResponseChunk(InferenceResponseChunk {
                            request_id: request.request_id.clone(),
                            data: String::new(),
                            encrypted_data: Some(EncryptedPayload {
                                ephemeral_public_key: encrypted.ephemeral_public_key,
                                ciphertext: encrypted.ciphertext,
                            }),
                        }),
                    )
                    .await?;
                    state.emitted_chunks.fetch_add(1, Ordering::AcqRel);
                }
                send_json(
                    socket,
                    &ProviderMessage::InferenceComplete(InferenceComplete {
                        request_id: request.request_id,
                        usage: UsageInfo {
                            prompt_tokens: 3,
                            completion_tokens: config.chunk_multiplier as u64,
                            reasoning_tokens: 0,
                        },
                        se_signature: String::new(),
                        response_hash: hex_digest(response_hasher.finalize().as_slice()),
                    }),
                )
                .await?;
                state.served_requests.fetch_add(1, Ordering::AcqRel);
            }
            CoordinatorMessage::AttestationChallenge(challenge) => {
                send_json(
                    socket,
                    &ProviderMessage::AttestationResponse(challenge_response(
                        signing_key,
                        &challenge.nonce,
                        &challenge.timestamp,
                    )?),
                )
                .await?;
            }
            CoordinatorMessage::Cancel(_) => {}
            _ => {}
        }
    }
}

async fn serve_rust(
    socket: &mut Socket,
    config: &Config,
    state: &PeerState,
    index: usize,
    generation: &mut watch::Receiver<u64>,
    signing_key: &SigningKey,
) -> Result<(), Error> {
    let mut prepares = BTreeMap::<String, Prepare>::new();
    loop {
        let message = tokio::select! {
            changed = generation.changed(), if index == 0 => {
                changed?;
                let _ = socket.close(None).await;
                return Ok(());
            }
            _ = sleep(Duration::from_secs(10)) => {
                socket.send(Message::Text(heartbeat_wire(&config.model).into())).await?;
                continue;
            }
            message = socket.next() => message.ok_or("Rust coordinator closed peer socket")??,
        };
        let Message::Text(text) = message else {
            continue;
        };
        let message: CoordinatorControlMessage = match serde_json::from_str(&text) {
            Ok(message) => message,
            Err(_) => continue,
        };
        match message {
            CoordinatorControlMessage::Prepare(prepare) => {
                if consume_one(&state.sent_unknown_armed) {
                    state
                        .sent_unknown_disconnects
                        .fetch_add(1, Ordering::AcqRel);
                    socket.close(None).await?;
                    return Ok(());
                }
                send_json(
                    socket,
                    &ProviderControlMessage::Prepared(Prepared {
                        identity: prepare.identity.clone(),
                        model: prepare.model.clone(),
                        request_digest: prepare.request_digest,
                        lease_ttl_ms: 5_000,
                        prompt_tokens: 3,
                        max_output_tokens: (8 * config.chunk_multiplier) as u64,
                        engine_queue_depth: 0,
                        reserved_kv_bytes: 2 * 1024 * 1024,
                        reserved_media_bytes: 0,
                        prefill_can_begin: true,
                        estimated_prefill_ms: Some(5),
                    }),
                )
                .await?;
                prepares.insert(prepare.identity.request_id.to_string(), prepare);
            }
            CoordinatorControlMessage::Start(start) => {
                apply_hedge_delay(state).await;
                send_json(
                    socket,
                    &ProviderControlMessage::StartAck(StartAck {
                        identity: start.identity.clone(),
                    }),
                )
                .await?;
                let prepare = prepares
                    .remove(&start.identity.request_id.to_string())
                    .ok_or("start arrived without prepare")?;
                serve_rust_output(socket, config, state, index, signing_key, prepare).await?;
            }
            CoordinatorControlMessage::Abort(abort) => {
                prepares.remove(&abort.identity.request_id.to_string());
                send_json(
                    socket,
                    &ProviderControlMessage::AbortAck(AbortAck {
                        identity: abort.identity,
                    }),
                )
                .await?;
            }
            CoordinatorControlMessage::Cancel(cancel) => {
                prepares.remove(&cancel.identity.request_id.to_string());
                send_json(
                    socket,
                    &ProviderControlMessage::CancelAck(CancelAck {
                        identity: cancel.identity,
                    }),
                )
                .await?;
            }
            CoordinatorControlMessage::QueryAttempt(query) => {
                send_json(
                    socket,
                    &ProviderControlMessage::AttemptStatus(AttemptStatus {
                        identity: query.identity,
                        state: AttemptStatusState::Unknown,
                        terminal_digest: None,
                    }),
                )
                .await?;
            }
            CoordinatorControlMessage::CoordinatorReplayFence(proof) => {
                send_json(
                    socket,
                    &ProviderControlMessage::ReplayFenceAck(ReplayFenceAck {
                        proof_id: proof.proof_id,
                        provider_id: proof.provider_id,
                        provider_process_generation: proof.provider_process_generation,
                    }),
                )
                .await?;
            }
            CoordinatorControlMessage::TerminalAck(_) => {}
        }
    }
}

async fn serve_rust_output(
    socket: &mut Socket,
    config: &Config,
    state: &PeerState,
    index: usize,
    signing_key: &SigningKey,
    prepare: Prepare,
) -> Result<(), Error> {
    let provider_private = provider_private()?;
    let recipient = decode_array::<32>(
        "ephemeral_public_key",
        &prepare.encrypted_body.ephemeral_public_key,
    )?;
    let chunks = response_chunks(config.chunk_multiplier, &config.model);
    let request_number = state.served_requests.load(Ordering::Acquire);
    let mut rolling = [0_u8; 32];
    let mut response_hasher = Sha256::new();
    for (sequence, chunk) in chunks.iter().enumerate() {
        let cumulative_tokens = if sequence == 0 {
            0
        } else {
            u64::try_from(sequence.min(config.chunk_multiplier))?
        };
        rolling = next_rolling_digest(rolling, u64::try_from(sequence)?, cumulative_tokens, chunk);
        response_hasher.update(chunk);
        let header = BinaryFrameHeader {
            kind: BinaryFrameKind::ResponseChunk,
            flags: if sequence + 1 == chunks.len() {
                BinaryFrameFlags::FINAL
            } else {
                BinaryFrameFlags::EMPTY
            },
            minor: 0,
            provider_id: prepare.identity.provider_id,
            provider_process_generation: prepare.identity.provider_process_generation,
            session_epoch: prepare.identity.session_epoch,
            request_id: prepare.identity.request_id,
            attempt_id: prepare.identity.attempt_id,
            reservation_id: prepare.identity.reservation_id,
            lease_id: prepare.identity.lease_id,
            nonce: unique_nonce(index, request_number, sequence),
            rolling_digest: rolling,
            sequence: u64::try_from(sequence)?,
            ciphertext_len: 0,
            cumulative_tokens,
        };
        let frame = seal_v2_frame(&provider_private, &recipient, header, chunk)?;
        socket.send(Message::Binary(frame.to_vec().into())).await?;
        state.emitted_chunks.fetch_add(1, Ordering::AcqRel);
    }
    let mut terminal = ProviderTerminal {
        identity: prepare.identity,
        outcome: TerminalOutcome::Completed,
        error_class: None,
        prompt_tokens: 3,
        completion_tokens: config.chunk_multiplier as u64,
        reasoning_tokens: 0,
        response_hash: Digest::new(response_hasher.finalize().into()),
        final_generated_tokens: config.chunk_multiplier as u64,
        rolling_digest: Digest::new(rolling),
        model: prepare.model,
        terminal_digest: Digest::default(),
        signature: TerminalSignature::default(),
    };
    terminal.terminal_digest = terminal.computed_digest()?;
    let signature: DerSignature = signing_key.sign(terminal.terminal_digest.as_bytes());
    terminal.signature = TerminalSignature::new(signature.as_bytes().to_vec());
    send_json(socket, &ProviderControlMessage::Terminal(terminal)).await?;
    state.served_requests.fetch_add(1, Ordering::AcqRel);
    Ok(())
}

async fn apply_hedge_delay(state: &PeerState) {
    if consume_one(&state.hedge_delays) {
        state.hedge_count.fetch_add(1, Ordering::AcqRel);
        sleep(Duration::from_millis(500)).await;
    }
}

fn record_replacement_if_pending(state: &PeerState, index: usize) {
    if index == 0 && consume_one(&state.replacement_pending) {
        state.replacement_count.fetch_add(1, Ordering::AcqRel);
    }
}

fn consume_one(counter: &AtomicUsize) -> bool {
    counter
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |value| {
            value.checked_sub(1)
        })
        .is_ok()
}

fn response_chunks(multiplier: usize, model: &str) -> Vec<Vec<u8>> {
    let mut chunks = Vec::with_capacity(multiplier + 2);
    chunks.push(
        format!(
            "data: {{\"id\":\"chatcmpl-pilot\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"{model}\",\"choices\":[{{\"index\":0,\"delta\":{{\"role\":\"assistant\"}},\"finish_reason\":null}}]}}\n\n"
        )
        .into_bytes(),
    );
    for index in 0..multiplier {
        chunks.push(
            format!(
                "data: {{\"id\":\"chatcmpl-pilot\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"{model}\",\"choices\":[{{\"index\":0,\"delta\":{{\"content\":\"pilot-{index}\"}},\"finish_reason\":{}}}]}}\n\n",
                if index + 1 == multiplier {
                    "\"stop\""
                } else {
                    "null"
                },
            )
            .into_bytes(),
        );
    }
    chunks.push(b"data: [DONE]\n\n".to_vec());
    chunks
}

fn registration_wire(
    key: &SigningKey,
    generation: ProviderProcessGenerationId,
    v2: bool,
    provider_token: &str,
    model: &str,
) -> String {
    let public_key = STANDARD.encode(key.verifying_key().to_sec1_point(false));
    let blob = format!(
        r#"{{"encryptionPublicKey":"{PROCESS_PUBLIC}","publicKey":"{public_key}","secureBootEnabled":true,"secureEnclaveAvailable":true,"sipEnabled":true,"timestamp":"2026-07-12T00:00:00Z"}}"#
    );
    let attestation = format!(
        r#"{{"attestation":{blob},"signature":"{}"}}"#,
        sign(key, blob.as_bytes())
    );
    let v2_fields = if v2 {
        format!(
            r#","auth_token":"{provider_token}","private_only":true,"provider_process_generation":"{generation}","protocol_capabilities":{{"protocol_major":2,"protocol_minor":0,"prepared_leases":true,"start_authorization":true,"structured_errors":true,"start_ack":true,"abort_ack":true,"cancel_ack":true,"durable_terminals":true,"model_lifecycle_events":true,"binary_payload_frames":true,"coordinator_replay_fences":true,"attempt_reconciliation":true}}"#
        )
    } else {
        String::new()
    };
    format!(
        r#"{{"type":"register","hardware":{{"machine_model":"Pilot","chip_name":"Pilot","chip_family":"M","chip_tier":"base","memory_gb":64,"memory_available_gb":32,"cpu_cores":{{"total":8,"performance":4,"efficiency":4}},"gpu_cores":8,"memory_bandwidth_gbs":100}},"models":[{{"id":"{model}","size_bytes":1,"model_type":"chat","quantization":"test","template_render_ok":true}}],"backend":"mlx-swift","version":"0.6.99-pilot","public_key":"{PROCESS_PUBLIC}","encrypted_response_chunks":true,"privacy_capabilities":{{"text_backend_inprocess":true,"text_proxy_disabled":true,"python_runtime_locked":true,"dangerous_modules_blocked":true,"sip_enabled":true,"anti_debug_enabled":true,"core_dumps_disabled":true,"env_scrubbed":true}},"attestation":{attestation},"prefill_tps":1000,"decode_tps":100{v2_fields}}}"#
    )
}

fn heartbeat_wire(model: &str) -> String {
    format!(
        r#"{{"type":"heartbeat","status":"ready","active_model":"{model}","stats":{{"requests_served":0,"tokens_generated":0}},"warm_models":["{model}"],"system_metrics":{{"memory_pressure":0.1,"cpu_usage":0.1,"thermal_state":"nominal"}},"backend_capacity":{{"slots":[{{"model":"{model}","state":"idle","num_running":0,"num_waiting":0,"max_concurrency":32,"active_tokens":0,"max_tokens_potential":0,"observed_decode_tps":100,"observed_prefill_tps":1000,"active_token_budget_used":0,"active_token_budget_max":1048576,"queued_token_budget":0}}],"gpu_memory_active_gb":1,"gpu_memory_peak_gb":1,"gpu_memory_cache_gb":0,"total_memory_gb":64,"free_for_load_gb":32}}}}"#
    )
}

fn challenge_response(
    key: &SigningKey,
    nonce: &str,
    timestamp: &str,
) -> Result<AttestationResponse, Error> {
    let mut response = AttestationResponse {
        nonce: nonce.to_owned(),
        signature: sign(key, format!("{nonce}{timestamp}").as_bytes()),
        status_signature: String::new(),
        public_key: PROCESS_PUBLIC.to_owned(),
        hypervisor_active: None,
        rdma_disabled: Some(true),
        sip_enabled: Some(true),
        secure_boot_enabled: Some(true),
        binary_hash: "pilot-binary".to_owned(),
        active_model_hash: String::new(),
        python_hash: String::new(),
        runtime_hash: String::new(),
        template_hashes: BTreeMap::new(),
        grpc_binary_hash: String::new(),
        model_hashes: BTreeMap::new(),
    };
    response.status_signature = sign(key, &response.canonical_status_bytes(timestamp)?);
    Ok(response)
}

async fn send_json<T: serde::Serialize>(socket: &mut Socket, value: &T) -> Result<(), Error> {
    socket
        .send(Message::Text(serde_json::to_string(value)?.into()))
        .await?;
    Ok(())
}

fn sign(key: &SigningKey, bytes: &[u8]) -> String {
    let signature: DerSignature = key.sign(bytes);
    STANDARD.encode(signature.as_bytes())
}

fn provider_private() -> Result<[u8; 32], Error> {
    Ok(STANDARD
        .decode(PROCESS_PRIVATE)?
        .try_into()
        .map_err(|value: Vec<u8>| format!("provider private key has {} bytes", value.len()))?)
}

fn unique_nonce(session: usize, request: u64, sequence: usize) -> [u8; 24] {
    let mut hasher = Sha256::new();
    hasher.update(b"darkbloom-objective9-pilot-nonce");
    hasher.update(session.to_be_bytes());
    hasher.update(request.to_be_bytes());
    hasher.update(sequence.to_be_bytes());
    let digest = hasher.finalize();
    let mut nonce = [0; 24];
    nonce.copy_from_slice(&digest[..24]);
    nonce
}

fn hex_digest(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn required(name: &str) -> Result<String, Error> {
    std::env::var(name)
        .ok()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("{name} is required").into())
}

fn parse_positive(name: &str) -> Result<usize, Error> {
    let value = required(name)?.parse::<usize>()?;
    if value == 0 {
        return Err(format!("{name} must be positive").into());
    }
    Ok(value)
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn directive_counter_is_consumed_exactly_once() {
        let counter = AtomicUsize::new(1);
        assert!(consume_one(&counter));
        assert!(!consume_one(&counter));
        assert_eq!(counter.load(Ordering::Acquire), 0);
    }

    #[test]
    fn coordinator_url_accepts_only_exact_explicit_loopback_http() {
        for value in [
            "http://localhost:18080",
            "http://127.0.0.1:18080/",
            "http://[::1]:18080",
        ] {
            assert!(parse_coordinator_url(value).is_ok(), "{value}");
        }
        for value in [
            "http:///tmp/coordinator.sock",
            "unix:///tmp/coordinator.sock",
            "http://127.0.0.2:18080",
            "http://user@127.0.0.1:18080",
            "http://127.0.0.1:18080/other",
            "http://127.0.0.1:18080?host=remote",
            "https://127.0.0.1:18080",
            "http://127.0.0.1",
        ] {
            assert!(parse_coordinator_url(value).is_err(), "{value}");
        }
    }
}
