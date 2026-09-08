//! The provider-session seam (plan §7.4, §15.2): two-lane writer handles,
//! control/data frames, per-attempt event sinks, and session commands.
//! Invariant: all submission is bounded and non-blocking at the call site;
//! wire completion is observed via [`OnWire`].

use std::time::Duration;

use bytes::Bytes;
use tokio::sync::{mpsc, oneshot};

use darkbloom_core::ids::{AttemptId, LeaseId, ProviderId, SessionEpoch};
use darkbloom_protocol::json_v1;
use darkbloom_protocol::json_v2;

use super::chunks::ChunkSender;

/// Protocol generation negotiated at registration.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProtocolGen {
    V1,
    V2,
}

/// Result of a writer-lane submission: resolved when the frame is on the wire
/// (plan §15.2: `WriteText` blocks to wire completion).
pub type OnWire = oneshot::Receiver<Result<(), WriteError>>;

#[derive(Debug, Clone, thiserror::Error)]
pub enum WriteError {
    #[error("session closed before write")]
    SessionClosed,
    #[error("write failed with ambiguous delivery")]
    Ambiguous,
}

/// Control-lane frames (small, strict priority — plan §15.2).
#[derive(Debug)]
pub enum ControlFrame {
    V1Cancel {
        request_id: String,
    },
    V2(Box<json_v2::FrameV2>),
    /// Raw pre-encoded JSON (challenges, trust status).
    RawJson(Bytes),
}

/// Data-lane frames (large inference payloads).
#[derive(Debug)]
pub enum DataFrame {
    /// v1 inference_request, pre-encoded (body already encrypted).
    V1InferenceRequest(Bytes),
    /// v2 prepare envelope: JSON control part plus binary body frame.
    V2Prepare {
        frame: Box<json_v2::FrameV2>,
        binary_body: Option<Bytes>,
    },
    RawJson(Bytes),
}

/// Events delivered to a request task's control sink (chunks bypass this and
/// go straight to the [`ChunkSender`] — plan §7.2).
#[derive(Debug)]
pub enum AttemptEvent {
    // --- v2 ---
    Prepared {
        lease: LeaseId,
        ttl: Duration,
        billable_prompt_tokens: u64,
        queue_depth: u32,
        prefill_can_start: bool,
        frame: Box<json_v2::PreparedFrame>,
    },
    Started,
    Aborted {
        reason: json_v2::AbortReason,
    },
    Cancelled,
    Terminal(Box<json_v2::TerminalFrame>),
    // --- v1 ---
    AcceptedV1,
    CompleteV1 {
        usage: Option<json_v1::UsageInfo>,
        se_signature: Option<String>,
        response_hash: Option<String>,
    },
    ErrorV1 {
        status_code: u16,
        message: String,
    },
    // --- transport ---
    /// The provider session ended (any epoch teardown).
    SessionLost,
    /// The chunk pipe rejected a chunk: consumer backpressure (plan §13.6).
    PipeOverflow,
}

/// Sinks a request task registers with the session for one attempt.
pub struct AttemptSinks {
    /// Control events (bounded; the session drops the attempt on overflow and
    /// emits `SessionLost` semantics rather than blocking its read loop).
    pub events: mpsc::Sender<AttemptEvent>,
    /// Content chunks, decrypted for v1 / raw ciphertext for v2 relay.
    pub chunks: ChunkSender,
}

/// Commands consumed by one provider session's demux/writer loops.
#[derive(Debug)]
pub enum SessionCommand {
    AttachAttempt {
        /// v1 request id or v2 attempt id in wire form, used for demux.
        wire_id: String,
        attempt: AttemptId,
        sinks: AttemptSinksHandle,
    },
    DetachAttempt {
        wire_id: String,
    },
}

/// Debug-friendly wrapper because `AttemptSinks` contains non-Debug senders.
pub struct AttemptSinksHandle(pub AttemptSinks);

impl std::fmt::Debug for AttemptSinksHandle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("AttemptSinksHandle")
    }
}

/// Clonable handle to one provider session. All submission is bounded and
/// non-blocking at the call site; wire completion is observed via [`OnWire`].
#[derive(Clone)]
pub struct SessionHandle {
    pub provider: ProviderId,
    pub epoch: SessionEpoch,
    pub protocol: ProtocolGen,
    control_tx: mpsc::Sender<(ControlFrame, oneshot::Sender<Result<(), WriteError>>)>,
    data_tx: mpsc::Sender<(DataFrame, oneshot::Sender<Result<(), WriteError>>)>,
    command_tx: mpsc::Sender<SessionCommand>,
}

/// Receiver ends consumed by the session's writer and demux loops.
pub struct SessionReceivers {
    pub control_rx: mpsc::Receiver<(ControlFrame, oneshot::Sender<Result<(), WriteError>>)>,
    pub data_rx: mpsc::Receiver<(DataFrame, oneshot::Sender<Result<(), WriteError>>)>,
    pub command_rx: mpsc::Receiver<SessionCommand>,
}

/// Lane capacities (plan §14): control small, data a few full frames.
#[derive(Debug, Clone, Copy)]
pub struct SessionLaneCaps {
    pub control: usize,
    pub data: usize,
    pub commands: usize,
}

impl Default for SessionLaneCaps {
    fn default() -> Self {
        Self {
            control: 64,
            data: 4,
            commands: 64,
        }
    }
}

/// Builds the channel pair for one session.
pub fn session_channels(
    provider: ProviderId,
    epoch: SessionEpoch,
    protocol: ProtocolGen,
    caps: SessionLaneCaps,
) -> (SessionHandle, SessionReceivers) {
    let (control_tx, control_rx) = mpsc::channel(caps.control);
    let (data_tx, data_rx) = mpsc::channel(caps.data);
    let (command_tx, command_rx) = mpsc::channel(caps.commands);
    (
        SessionHandle {
            provider,
            epoch,
            protocol,
            control_tx,
            data_tx,
            command_tx,
        },
        SessionReceivers {
            control_rx,
            data_rx,
            command_rx,
        },
    )
}

#[derive(Debug, thiserror::Error)]
pub enum SubmitError {
    #[error("lane full")]
    LaneFull,
    #[error("session closed")]
    Closed,
}

impl SessionHandle {
    /// Enqueue on the control lane. A full control lane is a session-fencing
    /// condition (plan §9.4.3) — the CALLER treats `LaneFull` accordingly.
    pub fn submit_control(&self, frame: ControlFrame) -> Result<OnWire, SubmitError> {
        let (tx, rx) = oneshot::channel();
        self.control_tx
            .try_send((frame, tx))
            .map_err(map_try_send)?;
        Ok(rx)
    }

    /// Enqueue on the data lane. A full data lane makes the provider
    /// temporarily ineligible (plan §9.4.2); callers fail fast.
    pub fn submit_data(&self, frame: DataFrame) -> Result<OnWire, SubmitError> {
        let (tx, rx) = oneshot::channel();
        self.data_tx.try_send((frame, tx)).map_err(map_try_send)?;
        Ok(rx)
    }

    /// True when the data lane currently has headroom (admission gate input).
    pub fn data_lane_has_headroom(&self) -> bool {
        self.data_tx.capacity() > 0
    }

    pub fn control_lane_has_headroom(&self) -> bool {
        self.control_tx.capacity() > 0
    }

    pub async fn attach_attempt(
        &self,
        wire_id: String,
        attempt: AttemptId,
        sinks: AttemptSinks,
    ) -> Result<(), SubmitError> {
        self.command_tx
            .send(SessionCommand::AttachAttempt {
                wire_id,
                attempt,
                sinks: AttemptSinksHandle(sinks),
            })
            .await
            .map_err(|_| SubmitError::Closed)
    }

    pub async fn detach_attempt(&self, wire_id: String) -> Result<(), SubmitError> {
        self.command_tx
            .send(SessionCommand::DetachAttempt { wire_id })
            .await
            .map_err(|_| SubmitError::Closed)
    }
}

fn map_try_send<T>(err: mpsc::error::TrySendError<T>) -> SubmitError {
    match err {
        mpsc::error::TrySendError::Full(_) => SubmitError::LaneFull,
        mpsc::error::TrySendError::Closed(_) => SubmitError::Closed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn session_lanes_report_headroom() {
        let (handle, _rx) = session_channels(
            ProviderId::new(uuid::Uuid::from_u128(1)),
            SessionEpoch::new(1),
            ProtocolGen::V2,
            SessionLaneCaps {
                control: 1,
                data: 1,
                commands: 1,
            },
        );
        assert!(handle.data_lane_has_headroom());
        let _wire = handle
            .submit_data(DataFrame::RawJson(Bytes::from_static(b"{}")))
            .unwrap();
        assert!(!handle.data_lane_has_headroom());
        let err = handle
            .submit_data(DataFrame::RawJson(Bytes::from_static(b"{}")))
            .unwrap_err();
        assert!(matches!(err, SubmitError::LaneFull));
    }
}
