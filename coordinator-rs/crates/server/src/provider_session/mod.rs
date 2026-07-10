//! One provider WebSocket connection: registration, epoch, two-lane writer,
//! frame demux, and attempt routing (plan §7.4, §15.2, §15.3).
//!
//! # Entry point
//!
//! `provider_session::serve(socket, deps)` — the HTTP adapter wires the
//! `GET /v1/providers/connect` upgrade to this call:
//!
//! ```ignore
//! router.route("/v1/providers/connect", get(|upgrade: WebSocketUpgrade| async {
//!     upgrade.max_message_size(deps.config.max_frame_bytes)
//!         .on_upgrade(move |socket| provider_session::serve(socket, deps))
//! }))
//! ```
//!
//! # Flow
//!
//! 1. Read the registration frame (v1 `register`; protocol v2 detected via
//!    the `protocol_v2` extension, [`json_v2::RegistrationV2`]).
//! 2. Verify identity evidence via the [`trust`] verifier (Secure Enclave
//!    attestation over raw preserved bytes; optional at the pilot trust
//!    level) and derive the stable [`ProviderId`]
//!    ([`registration::stable_provider_id`]).
//! 3. `FleetCommand::Connect` — the fleet mints the session epoch and the
//!    lane channels; the session receives [`contracts::ConnectAccept`].
//! 4. Split the socket: the [`writer`] task owns the sink and drains
//!    control-then-data with STRICT non-preemptive control priority,
//!    resolving each frame's `OnWire` oneshot after the socket write
//!    returns (Go `WriteText`-blocks-to-wire semantics, plan §15.2). The
//!    [`reader`] loop decodes and demuxes inbound frames.
//!
//! # v1 chunk ownership (design decision)
//!
//! The contract delivers the per-request session secret key to the request
//! task, never to the session — so the session CANNOT decrypt v1 chunks.
//! Instead it validates the sender key (the payload's ephemeral key must
//! equal the provider's registered X25519 key — plan §9.1.7), base64-decodes
//! the ciphertext, and forwards the RAW `nonce || box` bytes through the
//! [`contracts::ChunkSender`] — the exact input the request task's
//! precomputed shared key opens. The request task owns decryption: one
//! `nacl_box::precompute_shared_key` per attempt, then one symmetric open
//! per chunk (the Go `chunkKeyCache` equivalent, moved to the natural owner
//! of the key). The session never holds request key material and never
//! logs chunk bytes.
//!
//! # Keepalive and wire posture (design decision)
//!
//! The coordinator does NOT send WebSocket pings. Liveness is
//! provider-driven: heartbeats arrive every ~30 s and any inbound frame
//! advances the session's read deadline ([`SessionConfig::read_timeout`],
//! 90 s — the Go eviction-sweep parity); a silent socket is torn down at
//! the deadline. Inbound provider pings are answered automatically by the
//! WebSocket layer (tungstenite queues the pong), which also keeps Caddy's
//! proxied connection active. Outbound stalls are caught independently by
//! the writer's per-frame [`SessionConfig::write_timeout`] — including the
//! final close handshake. permessage-deflate is never negotiated (axum
//! offers no deflate extension): chunk payloads are ciphertext, so
//! compression would be pure CPU waste.
//!
//! # Supersede fencing (design decision)
//!
//! The fleet is the epoch authority. On supersede it (1) submits the
//! reserved in-band fence sentinel ([`writer::FENCE_FRAME`]) on the OLD
//! epoch's control lane — the writer recognizes it and tears down
//! immediately — and (2) drops its [`contracts::SessionHandle`], so even if
//! the sentinel could not be enqueued, the lanes close once outstanding
//! grant clones drop (the fallback fence). Either way: queued writes
//! resolve with [`WriteError::SessionClosed`], the socket closes, attached
//! attempts get [`AttemptEvent::SessionLost`], and the old session's own
//! `Disconnect{epoch}` is ignored by the fleet as stale (plan §9.1.2).
//! Teardown from the old epoch can never remove the new session.

mod attempts;
mod challenge;
mod heartbeat;
mod reader;
mod registration;
mod v1;
mod v2;
mod writer;

use std::sync::Arc;
use std::time::Duration;

use axum::extract::ws::WebSocket;
use futures::StreamExt;
use tokio::sync::{mpsc, oneshot};
use tokio_util::sync::CancellationToken;

use darkbloom_core::ids::{CoordinatorEpoch, ProviderId, SessionEpoch};
#[allow(unused_imports)] // doc links
use darkbloom_protocol::json_v2;

use crate::contracts::{
    self, ConnectAccept, CoordinatorKeys, FleetCommand, FleetHandle, ProtocolGen, SessionLaneCaps,
    SessionSeed,
};
#[allow(unused_imports)] // doc links
use crate::contracts::{AttemptEvent, WriteError};
use crate::trust::TrustVerifier;

pub use registration::{stable_provider_id, PROVIDER_ID_NAMESPACE};
pub(crate) use writer::FENCE_FRAME;

/// Session tunables with pilot defaults mirroring the Go coordinator where
/// one exists.
#[derive(Debug, Clone)]
pub struct SessionConfig {
    /// Maximum inbound frame size (32 MiB — sized for sealed vision
    /// payloads; the WebSocket upgrade limit should carry the same value).
    pub max_frame_bytes: usize,
    /// Deadline for the registration frame on a fresh connection.
    pub registration_timeout: Duration,
    /// Read liveness bound (~Go's 90s heartbeat eviction sweep): a session
    /// with no inbound frame for this long is torn down.
    pub read_timeout: Duration,
    /// Attestation challenge cadence (initial challenge fires immediately).
    pub challenge_interval: Duration,
    /// Per-frame write deadline before the session is declared stalled
    /// (plan §18: writer stall closes the session).
    pub write_timeout: Duration,
    /// Zombie-stream cancel throttle per request id (Go `zombie_stream.go`).
    pub zombie_cancel_throttle: Duration,
    /// Lane capacities handed to the fleet in the [`SessionSeed`].
    pub lane_caps: SessionLaneCaps,
}

impl Default for SessionConfig {
    fn default() -> Self {
        Self {
            max_frame_bytes: 32 * 1024 * 1024,
            registration_timeout: Duration::from_secs(10),
            read_timeout: Duration::from_secs(90),
            challenge_interval: Duration::from_secs(5 * 60),
            write_timeout: Duration::from_secs(30),
            zombie_cancel_throttle: Duration::from_secs(10),
            lane_caps: SessionLaneCaps::default(),
        }
    }
}

/// Everything one session needs. Cheap to clone per connection.
#[derive(Clone)]
pub struct SessionDeps {
    pub fleet: FleetHandle,
    pub trust: Arc<TrustVerifier>,
    /// Coordinator X25519 identity (secret zeroized by the crypto layer).
    pub keys: Arc<CoordinatorKeys>,
    /// Resolves the provider's registration `auth_token` to its earnings
    /// account (the paid-routing beneficiary, plan §11.2). The pilot auth
    /// surface is API keys, so the ledger's [`contracts::ApiKeyStore`] is
    /// the resolver; [`NoProviderAuth`] disables beneficiary resolution for
    /// harnesses without a database.
    pub auth: Arc<dyn contracts::ApiKeyStore>,
    /// Single-active coordinator fence: v2 frames carrying a different
    /// coordinator epoch are dropped (plan §10.2).
    pub coordinator_epoch: CoordinatorEpoch,
    pub config: SessionConfig,
}

/// [`contracts::ApiKeyStore`] that resolves nothing: providers register
/// without a beneficiary and paid routing gates them out (plan §11.2).
pub struct NoProviderAuth;

#[async_trait::async_trait]
impl contracts::ApiKeyStore for NoProviderAuth {
    async fn validate(&self, _token: &str) -> Option<contracts::ApiKeyRecord> {
        None
    }
}

/// Immutable per-session facts shared by the reader and its demux handlers.
pub(crate) struct SessionContext {
    pub provider: ProviderId,
    pub epoch: SessionEpoch,
    pub protocol: ProtocolGen,
    /// The registered X25519 key every v1 encrypted chunk must be sent with.
    pub provider_x25519_b64: String,
    /// SE public key from a valid registration attestation; absent means no
    /// challenge round can verify (pilot: the provider stays at its
    /// registration verdict).
    pub se_public_key: Option<String>,
    pub statics: heartbeat::ProviderStatics,
}

/// Serves one upgraded provider WebSocket to completion. Never panics; all
/// failure paths tear the session down and (post-connect) notify the fleet.
pub async fn serve(socket: WebSocket, deps: SessionDeps) {
    let mut socket = socket;
    let outcome = match registration::register(&mut socket, &deps).await {
        Ok(outcome) => outcome,
        Err(err) => {
            tracing::info!(error = %err, "provider registration failed");
            let _ = socket.send(axum::extract::ws::Message::Close(None)).await;
            return;
        }
    };

    let provider = outcome.summary.provider;
    let seed = SessionSeed {
        protocol: outcome.summary.protocol,
        lane_caps: deps.config.lane_caps,
    };
    let (reply_tx, reply_rx) = oneshot::channel();
    let connect = FleetCommand::Connect {
        registration: Box::new(outcome.summary.clone()),
        session_seed: Box::new(seed),
        reply: reply_tx,
    };
    if deps.fleet.commands.send(connect).await.is_err() {
        tracing::warn!(provider = %provider, "fleet unavailable at connect");
        return;
    }
    let accept: ConnectAccept = match reply_rx.await {
        Ok(Ok(accept)) => accept,
        Ok(Err(rejected)) => {
            tracing::warn!(provider = %provider, error = %rejected, "connect rejected");
            let _ = socket.send(axum::extract::ws::Message::Close(None)).await;
            return;
        }
        Err(_) => return,
    };

    // Registration evidence becomes the first epoch-fenced trust verdict.
    let verdict_cmd = FleetCommand::TrustVerdict {
        provider,
        trust_epoch: outcome.verdict.trust_epoch,
        verdict: outcome.verdict.verdict.clone(),
    };
    if deps.fleet.commands.send(verdict_cmd).await.is_err() {
        return;
    }

    let ctx = SessionContext {
        provider,
        epoch: accept.epoch,
        protocol: outcome.summary.protocol,
        provider_x25519_b64: outcome.summary.public_key_b64.clone(),
        se_public_key: outcome.verdict.se_public_key.clone(),
        statics: outcome.statics,
    };

    run_session(socket, deps, ctx, accept).await;
}

/// Wires the writer task and reader loop for one accepted session and joins
/// them; on return the fleet has been told `Disconnect{epoch}`.
async fn run_session(
    socket: WebSocket,
    deps: SessionDeps,
    ctx: SessionContext,
    accept: ConnectAccept,
) {
    let provider = ctx.provider;
    let epoch = ctx.epoch;
    let cancel = CancellationToken::new();
    let attempts = attempts::shared();
    let (sink, stream) = socket.split();

    // Session-originated frames (challenges, zombie cancels, test acks) ride
    // an internal lane with the same control-class priority; the session
    // never holds its own SessionHandle, so fleet-side handle drop is the
    // complete fence signal.
    let (internal_tx, internal_rx) = mpsc::channel::<writer::SessionWrite>(64);

    let contracts::SessionReceivers {
        control_rx,
        data_rx,
        command_rx,
    } = accept.receivers;

    let writer_task = tokio::spawn(writer::run_writer(writer::WriterInputs {
        sink,
        control_rx,
        data_rx,
        internal_rx,
        attempts: attempts.clone(),
        cancel: cancel.clone(),
        write_timeout: deps.config.write_timeout,
    }));

    let reader = reader::Reader::new(
        stream,
        command_rx,
        internal_tx,
        attempts.clone(),
        ctx,
        deps.clone(),
        cancel.clone(),
    );
    reader.run().await;

    // Reader exit is authoritative teardown: stop the writer, fail every
    // attached attempt, and report the (possibly stale) disconnect.
    cancel.cancel();
    let _ = writer_task.await;

    let orphaned = attempts::take_all_sinks(&attempts);
    for (sinks, reserved) in orphaned {
        // A full lane cannot swallow the mandatory SessionLost: fall back
        // to the permit reserved at attach (plan §9.4.5).
        if sinks
            .events
            .try_send(contracts::AttemptEvent::SessionLost)
            .is_err()
        {
            if let Some(permit) = reserved {
                let _ = permit.send(contracts::AttemptEvent::SessionLost);
            }
        }
    }
    let _ = deps
        .fleet
        .commands
        .send(FleetCommand::Disconnect { provider, epoch })
        .await;
    tracing::info!(provider = %provider, epoch = epoch.get(), "provider session ended");
}
