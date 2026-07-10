//! The session read loop: socket frames, attach/detach commands, and the
//! challenge timer (plan §7.4). Demux handlers live in [`super::v1`] and
//! [`super::v2`].

use axum::extract::ws::{Message, WebSocket};
use futures::stream::SplitStream;
use futures::StreamExt;
use serde::Deserialize;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use darkbloom_protocol::json_v1::peek_type;

use crate::contracts::{AttemptEvent, SessionCommand};

use super::attempts::{self, SharedAttempts, ZombieCanceller};
use super::challenge::ChallengeState;
use super::writer::SessionWrite;
use super::{SessionContext, SessionDeps};

pub(crate) struct Reader {
    pub(super) stream: SplitStream<WebSocket>,
    pub(super) command_rx: mpsc::Receiver<SessionCommand>,
    pub(super) internal_tx: mpsc::Sender<SessionWrite>,
    pub(super) attempts: SharedAttempts,
    pub(super) zombie: ZombieCanceller,
    pub(super) challenge: ChallengeState,
    pub(super) ctx: SessionContext,
    pub(super) deps: SessionDeps,
    pub(super) cancel: CancellationToken,
    /// Session-local monotonic heartbeat revision (plan §10.7: one revision
    /// domain per session; the fleet resets presence on reconnect).
    pub(super) heartbeat_revision: u64,
    /// Frames dropped for fencing/integrity reasons (plan §10.2 security
    /// counter).
    pub(super) security_drops: u64,
    /// Frames dropped as benign protocol residue (unknown types, decode
    /// misses, tombstoned starts).
    pub(super) stale_drops: u64,
}

/// Why one delivered event could not be handed to the request task.
pub(super) enum Deliver {
    Ok,
    NoAttempt,
    /// Events lane overflow: the attempt was dropped with `SessionLost`
    /// semantics per the contract, without blocking the read loop.
    Dropped,
}

impl Reader {
    pub(crate) fn new(
        stream: SplitStream<WebSocket>,
        command_rx: mpsc::Receiver<SessionCommand>,
        internal_tx: mpsc::Sender<SessionWrite>,
        attempts: SharedAttempts,
        ctx: SessionContext,
        deps: SessionDeps,
        cancel: CancellationToken,
    ) -> Self {
        let zombie = ZombieCanceller::new(deps.config.zombie_cancel_throttle);
        Self {
            stream,
            command_rx,
            internal_tx,
            attempts,
            zombie,
            challenge: ChallengeState::default(),
            ctx,
            deps,
            cancel,
            heartbeat_revision: 0,
            security_drops: 0,
            stale_drops: 0,
        }
    }

    pub(crate) async fn run(mut self) {
        // First tick fires immediately: the initial challenge goes out on
        // registration, then every interval (Go challengeLoop).
        let mut challenge_timer = tokio::time::interval(self.deps.config.challenge_interval);
        challenge_timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

        // Read-liveness deadline (~Go's 90s eviction sweep). Advanced ONLY
        // when a frame actually arrives, so attach/detach or timer churn
        // can never keep a silent socket alive.
        let mut read_deadline = tokio::time::Instant::now() + self.deps.config.read_timeout;

        loop {
            tokio::select! {
                biased;
                () = self.cancel.cancelled() => break,
                cmd = self.command_rx.recv() => match cmd {
                    Some(cmd) => self.handle_command(cmd),
                    // Every SessionHandle dropped: the fleet fenced this
                    // epoch (supersede or shutdown).
                    None => {
                        tracing::info!(provider = %self.ctx.provider,
                            epoch = self.ctx.epoch.get(), "session fenced by fleet");
                        break;
                    }
                },
                _ = challenge_timer.tick() => self.send_challenge().await,
                frame = tokio::time::timeout_at(read_deadline, self.stream.next()) => {
                    match frame {
                        Err(_) => {
                            tracing::info!(provider = %self.ctx.provider,
                                "session read liveness timeout");
                            break;
                        }
                        Ok(None) => break,
                        Ok(Some(Err(err))) => {
                            tracing::info!(provider = %self.ctx.provider, error = %err,
                                "session read error");
                            break;
                        }
                        Ok(Some(Ok(message))) => {
                            read_deadline =
                                tokio::time::Instant::now() + self.deps.config.read_timeout;
                            if !self.handle_message(message).await {
                                break;
                            }
                        }
                    }
                }
            }
        }

        if self.security_drops > 0 {
            tracing::warn!(provider = %self.ctx.provider,
                security_drops = self.security_drops,
                "session ended with security-dropped frames");
        }
    }

    fn handle_command(&mut self, cmd: SessionCommand) {
        match cmd {
            SessionCommand::AttachAttempt {
                wire_id,
                attempt,
                sinks,
            } => attempts::lock(&self.attempts).attach(wire_id, attempt, sinks.0),
            SessionCommand::DetachAttempt { wire_id } => {
                attempts::lock(&self.attempts).detach(&wire_id);
            }
        }
    }

    async fn send_challenge(&mut self) {
        if let Some(write) = self.challenge.next_challenge(&self.ctx) {
            // Internal lane = control priority; a full internal lane means
            // the writer is stalled and teardown is already imminent.
            let _ = self.internal_tx.try_send(write);
        }
    }

    /// Returns false when the session must tear down.
    async fn handle_message(&mut self, message: Message) -> bool {
        match message {
            Message::Text(text) => {
                let data = text.as_str().as_bytes();
                if data.len() > self.deps.config.max_frame_bytes {
                    self.security_drops += 1;
                    tracing::warn!(provider = %self.ctx.provider, len = data.len(),
                        "oversize text frame; closing session");
                    return false;
                }
                // Copy out so handlers own the bytes without borrow games;
                // frames are small except inference payloads, which v1
                // providers never send coordinator-bound.
                let owned = data.to_vec();
                self.dispatch_text(&owned).await;
                true
            }
            Message::Binary(binary) => {
                if self.ctx.protocol == crate::contracts::ProtocolGen::V2 {
                    self.handle_binary(binary).await;
                } else {
                    self.security_drops += 1;
                    tracing::warn!(provider = %self.ctx.provider,
                        "binary frame on v1 session dropped");
                }
                true
            }
            Message::Close(_) => false,
            Message::Ping(_) | Message::Pong(_) => true,
        }
    }

    /// Single-parse dispatch: `peek_type` fast path with an envelope
    /// fallback, then one targeted struct decode (Go `type_scan.go`).
    async fn dispatch_text(&mut self, data: &[u8]) {
        let Some(frame_type) = frame_type(data) else {
            self.stale_drops += 1;
            tracing::debug!(provider = %self.ctx.provider, "undecodable frame dropped");
            return;
        };
        if self.ctx.protocol == crate::contracts::ProtocolGen::V2
            && super::v2::is_v2_type(&frame_type)
        {
            self.handle_v2_text(&frame_type, data).await;
            return;
        }
        self.handle_v1_text(&frame_type, data).await;
    }

    /// Decodes one concrete frame; a decode miss is counted, never logged
    /// with content (privacy: frames can carry ciphertext or key material).
    pub(super) fn decode<T: serde::de::DeserializeOwned>(
        &mut self,
        frame_type: &str,
        data: &[u8],
    ) -> Option<T> {
        match serde_json::from_slice(data) {
            Ok(value) => Some(value),
            Err(_) => {
                self.stale_drops += 1;
                tracing::debug!(provider = %self.ctx.provider, frame_type,
                    "frame payload decode failed");
                None
            }
        }
    }

    /// Delivers one control event to an attached attempt with the contract
    /// overflow policy: a full events lane drops the attempt (`SessionLost`
    /// semantics) rather than blocking the read loop.
    pub(super) fn deliver_event(&mut self, wire_id: &str, event: AttemptEvent) -> Deliver {
        let mut table = attempts::lock(&self.attempts);
        let Some(entry) = table.entry_mut(wire_id) else {
            return Deliver::NoAttempt;
        };
        let Some(sinks) = entry.sinks.as_ref() else {
            return Deliver::NoAttempt;
        };
        match sinks.events.try_send(event) {
            Ok(()) => Deliver::Ok,
            Err(mpsc::error::TrySendError::Full(_)) => {
                if let Some(sinks) = entry.sinks.take() {
                    let _ = sinks.events.try_send(AttemptEvent::SessionLost);
                }
                table.detach(wire_id);
                tracing::warn!(wire_id, "attempt event lane overflow; attempt dropped");
                Deliver::Dropped
            }
            Err(mpsc::error::TrySendError::Closed(_)) => {
                table.detach(wire_id);
                Deliver::NoAttempt
            }
        }
    }

    pub(super) fn count_security_drop(&mut self, reason: &'static str) {
        self.security_drops += 1;
        tracing::warn!(provider = %self.ctx.provider, reason, "frame security-dropped");
    }
}

#[derive(Deserialize)]
struct TypeEnvelope {
    #[serde(rename = "type", default)]
    frame_type: String,
}

fn frame_type(data: &[u8]) -> Option<String> {
    if let Some(t) = peek_type(data) {
        return Some(t.to_owned());
    }
    serde_json::from_slice::<TypeEnvelope>(data)
        .ok()
        .map(|e| e.frame_type)
        .filter(|t| !t.is_empty())
}
