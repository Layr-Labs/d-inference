//! The single writer task owning the WebSocket sink (plan §15.2).
//!
//! Two-lane semantics ported from Go `registry/provider_writer.go`:
//!
//! - STRICT non-preemptive control priority: whenever both lanes hold a
//!   frame, the control frame is served first. An in-flight data write
//!   finishes first (non-preemptive; an explicit measured residual).
//! - FIFO holds only within a lane; ordering across lanes is unspecified —
//!   except that a cancel submitted after a request's `OnWire` resolved can
//!   never precede it (single writer, single sink).
//! - Each frame's `OnWire` oneshot resolves only after the socket write
//!   returned (Go `WriteText`-blocks-to-wire semantics).
//! - A frame exceeding the per-frame write deadline is a writer stall: the
//!   submitter gets [`WriteError::Ambiguous`] (the bytes may be partially
//!   on the wire) and the session closes (plan §18: writer stall closes the
//!   provider session and fails affected attempts explicitly).
//! - When every contract-lane sender is gone (fleet supersede/shutdown
//!   fence) or on teardown, queued frames resolve with
//!   [`WriteError::SessionClosed`].
//!
//! Session-originated frames (challenges, trust status, zombie cancels)
//! ride the internal lane at control priority, keeping the session free of
//! its own `SessionHandle` so the fleet's handle drop is a complete fence.

use axum::extract::ws::{Message, Utf8Bytes, WebSocket};
use bytes::Bytes;
use futures::stream::SplitSink;
use futures::SinkExt;
use tokio::sync::{mpsc, oneshot};
use tokio_util::sync::CancellationToken;

use darkbloom_protocol::json_v1::CancelMessage;

use crate::contracts::{ControlFrame, DataFrame, WriteError};

use super::attempts::{self, ScopeBinding, SharedAttempts};

/// Coordinator-reserved in-band fence frame (never a legal wire frame).
///
/// On supersede/shutdown the fleet submits this on the OLD epoch's control
/// lane before dropping its handle: the writer recognizes it as a poison
/// pill and tears the session down immediately, without waiting for every
/// outstanding grant clone of the handle to drop (which remains the
/// fallback fence — lane closure). It is never written to the socket.
pub(crate) const FENCE_FRAME: &[u8] = br#"{"type":"__darkbloom.session.fence__"}"#;

/// One session-originated write.
pub(crate) struct SessionWrite {
    pub frame: OutFrame,
    pub on_wire: Option<oneshot::Sender<Result<(), WriteError>>>,
}

/// Encoded wire form of one submission (a v2 prepare is a JSON control part
/// plus an optional binary body frame — both count as ONE submission whose
/// `OnWire` resolves after the last write).
pub(crate) enum OutFrame {
    Text(Bytes),
    TextThenBinary { text: Bytes, binary: Bytes },
}

type OnWireTx = oneshot::Sender<Result<(), WriteError>>;

pub(crate) struct WriterInputs {
    pub sink: SplitSink<WebSocket, Message>,
    pub control_rx: mpsc::Receiver<(ControlFrame, OnWireTx)>,
    pub data_rx: mpsc::Receiver<(DataFrame, OnWireTx)>,
    pub internal_rx: mpsc::Receiver<SessionWrite>,
    pub attempts: SharedAttempts,
    pub cancel: CancellationToken,
    pub write_timeout: std::time::Duration,
}

pub(crate) async fn run_writer(inputs: WriterInputs) {
    let WriterInputs {
        mut sink,
        mut control_rx,
        mut data_rx,
        mut internal_rx,
        attempts,
        cancel,
        write_timeout,
    } = inputs;

    let mut control_open = true;
    let mut data_open = true;

    loop {
        if !control_open && !data_open {
            // Every contract sender dropped: the fleet fenced this epoch.
            tracing::debug!("session writer fenced: contract lanes closed");
            break;
        }
        tokio::select! {
            biased;
            () = cancel.cancelled() => break,
            write = internal_rx.recv() => match write {
                Some(SessionWrite { frame, on_wire }) => {
                    if !write_frame(&mut sink, frame, on_wire, write_timeout).await {
                        break;
                    }
                }
                // The reader (sole internal sender) is gone.
                None => break,
            },
            submission = control_rx.recv(), if control_open => match submission {
                Some((frame, on_wire)) => {
                    if is_fence(&frame) {
                        let _ = on_wire.send(Err(WriteError::SessionClosed));
                        tracing::debug!("session writer fenced: supersede sentinel");
                        break;
                    }
                    let out = encode_control(frame, &attempts);
                    if !write_encoded(&mut sink, out, on_wire, write_timeout).await {
                        break;
                    }
                }
                None => control_open = false,
            },
            submission = data_rx.recv(), if data_open => match submission {
                Some((frame, on_wire)) => {
                    let out = encode_data(frame, &attempts);
                    if !write_encoded(&mut sink, out, on_wire, write_timeout).await {
                        break;
                    }
                }
                None => data_open = false,
            },
        }
    }

    drain(&mut control_rx, &mut data_rx, &mut internal_rx);
    let _ = sink.send(Message::Close(None)).await;
    let _ = sink.close().await;
    // Reader teardown trigger: the writer never outlives the session.
    cancel.cancel();
}

/// Resolves queued submissions with `SessionClosed` — never silently drops
/// a waiter (plan §9.4.5).
fn drain(
    control_rx: &mut mpsc::Receiver<(ControlFrame, OnWireTx)>,
    data_rx: &mut mpsc::Receiver<(DataFrame, OnWireTx)>,
    internal_rx: &mut mpsc::Receiver<SessionWrite>,
) {
    control_rx.close();
    data_rx.close();
    internal_rx.close();
    while let Ok((_, on_wire)) = control_rx.try_recv() {
        let _ = on_wire.send(Err(WriteError::SessionClosed));
    }
    while let Ok((_, on_wire)) = data_rx.try_recv() {
        let _ = on_wire.send(Err(WriteError::SessionClosed));
    }
    while let Ok(write) = internal_rx.try_recv() {
        if let Some(on_wire) = write.on_wire {
            let _ = on_wire.send(Err(WriteError::SessionClosed));
        }
    }
}

fn is_fence(frame: &ControlFrame) -> bool {
    matches!(frame, ControlFrame::RawJson(bytes) if bytes.as_ref() == FENCE_FRAME)
}

fn encode_control(
    frame: ControlFrame,
    attempts: &SharedAttempts,
) -> Result<OutFrame, &'static str> {
    match frame {
        ControlFrame::V1Cancel { request_id } => {
            let msg = CancelMessage {
                request_id,
                ..Default::default()
            };
            serde_json::to_vec(&msg)
                .map(|v| OutFrame::Text(Bytes::from(v)))
                .map_err(|_| "cancel encode failed")
        }
        ControlFrame::V2(frame) => {
            // Remember the abort reason so the provider's bare `aborted`
            // acknowledgement can carry it back to the request task.
            if let darkbloom_protocol::json_v2::FrameV2::Abort(abort) = frame.as_ref() {
                attempts::lock(attempts)
                    .record_abort_reason(abort.scope.attempt_id.to_string(), abort.reason);
            }
            frame
                .encode()
                .map(|v| OutFrame::Text(Bytes::from(v)))
                .map_err(|_| "v2 frame encode failed")
        }
        ControlFrame::RawJson(bytes) => Ok(OutFrame::Text(bytes)),
    }
}

fn encode_data(frame: DataFrame, attempts: &SharedAttempts) -> Result<OutFrame, &'static str> {
    match frame {
        DataFrame::V1InferenceRequest(bytes) | DataFrame::RawJson(bytes) => {
            Ok(OutFrame::Text(bytes))
        }
        DataFrame::V2Prepare { frame, binary_body } => {
            // Record the outbound identity BEFORE the frame can reach the
            // provider: every inbound frame for this attempt must echo this
            // nonce and digest (plan §10.2).
            if let Some(scope) = frame.scope() {
                attempts::lock(attempts).bind(
                    scope.attempt_id.to_string(),
                    ScopeBinding {
                        nonce: scope.dispatch_nonce,
                        digest: scope.request_digest,
                    },
                );
            }
            let text = frame
                .encode()
                .map(Bytes::from)
                .map_err(|_| "prepare encode failed")?;
            Ok(match binary_body {
                Some(binary) => OutFrame::TextThenBinary { text, binary },
                None => OutFrame::Text(text),
            })
        }
    }
}

async fn write_encoded(
    sink: &mut SplitSink<WebSocket, Message>,
    encoded: Result<OutFrame, &'static str>,
    on_wire: OnWireTx,
    write_timeout: std::time::Duration,
) -> bool {
    match encoded {
        Ok(frame) => write_frame(sink, frame, Some(on_wire), write_timeout).await,
        Err(reason) => {
            // Encode failures are structurally impossible for well-formed
            // frames; treat as a caller error, never a session fault.
            tracing::error!(reason, "frame encode failed");
            let _ = on_wire.send(Err(WriteError::Ambiguous));
            true
        }
    }
}

/// Writes one frame (one or two socket messages) and resolves `on_wire`
/// after the write returns. Returns false when the writer must exit.
async fn write_frame(
    sink: &mut SplitSink<WebSocket, Message>,
    frame: OutFrame,
    on_wire: Option<OnWireTx>,
    write_timeout: std::time::Duration,
) -> bool {
    let result = match frame {
        OutFrame::Text(text) => send_text(sink, text, write_timeout).await,
        OutFrame::TextThenBinary { text, binary } => {
            let first = send_text(sink, text, write_timeout).await;
            match first {
                Ok(()) => send_one(sink, Message::Binary(binary), write_timeout).await,
                Err(err) => Err(err),
            }
        }
    };
    let ok = result.is_ok();
    if let Some(on_wire) = on_wire {
        let _ = on_wire.send(result);
    }
    ok
}

async fn send_text(
    sink: &mut SplitSink<WebSocket, Message>,
    text: Bytes,
    write_timeout: std::time::Duration,
) -> Result<(), WriteError> {
    // Contract text frames are JSON produced by serde or the request task;
    // reject (never panic on) invalid UTF-8.
    let utf8 = Utf8Bytes::try_from(text).map_err(|_| WriteError::Ambiguous)?;
    send_one(sink, Message::Text(utf8), write_timeout).await
}

async fn send_one(
    sink: &mut SplitSink<WebSocket, Message>,
    message: Message,
    write_timeout: std::time::Duration,
) -> Result<(), WriteError> {
    match tokio::time::timeout(write_timeout, sink.send(message)).await {
        Ok(Ok(())) => Ok(()),
        // Send started but failed or stalled: delivery is ambiguous.
        Ok(Err(_)) | Err(_) => Err(WriteError::Ambiguous),
    }
}
