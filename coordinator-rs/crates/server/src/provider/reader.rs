//! Strict bounded decoding and identity fencing for provider input.

use std::{fmt, sync::Arc, time::Duration};

use axum::extract::ws::Message;
use darkbloom_coordinator_protocol::{
    MAX_V2_BINARY_FRAME_LEN, V2_BINARY_HEADER_LEN,
    v1::{ProviderMessage, parse_provider_message},
    v2::{ProviderControlMessage, ProviderTerminal, decode_binary_frame},
};
use futures_util::{Stream, StreamExt};
use serde::Deserialize;
use thiserror::Error;
use tokio::{sync::oneshot, time::timeout};
use tokio_util::sync::CancellationToken;

use super::types::{
    BinarySessionFrame, NegotiatedProtocol, RegistrationFrame, SessionEvent, SessionEventSendError,
    SessionEventSender, SessionIdentity,
};

/// Absolute JSON bound independent of per-deployment tuning.
pub const MAX_PROVIDER_JSON_BYTES: usize = 4 * 1024 * 1024;

/// Strict inbound allocation limits.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ProviderReaderConfig {
    /// Maximum UTF-8 JSON frame size.
    pub maximum_json_bytes: usize,
    /// Maximum complete v2 binary frame, including the exact 192-byte header.
    pub maximum_binary_bytes: usize,
}

impl Default for ProviderReaderConfig {
    fn default() -> Self {
        Self {
            maximum_json_bytes: 1024 * 1024,
            maximum_binary_bytes: MAX_V2_BINARY_FRAME_LEN,
        }
    }
}

impl ProviderReaderConfig {
    /// Validates finite bounds before accepting a connection.
    pub fn validate(self) -> Result<Self, ProviderReaderConfigError> {
        if self.maximum_json_bytes == 0 {
            return Err(ProviderReaderConfigError::ZeroJsonLimit);
        }
        if self.maximum_json_bytes > MAX_PROVIDER_JSON_BYTES {
            return Err(ProviderReaderConfigError::JsonLimitTooLarge {
                actual: self.maximum_json_bytes,
                maximum: MAX_PROVIDER_JSON_BYTES,
            });
        }
        if self.maximum_binary_bytes < V2_BINARY_HEADER_LEN {
            return Err(ProviderReaderConfigError::BinaryLimitBelowHeader {
                actual: self.maximum_binary_bytes,
                required: V2_BINARY_HEADER_LEN,
            });
        }
        if self.maximum_binary_bytes > MAX_V2_BINARY_FRAME_LEN {
            return Err(ProviderReaderConfigError::BinaryLimitTooLarge {
                actual: self.maximum_binary_bytes,
                maximum: MAX_V2_BINARY_FRAME_LEN,
            });
        }
        Ok(self)
    }
}

/// Invalid reader bounds.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum ProviderReaderConfigError {
    /// JSON must have a finite positive allowance.
    #[error("provider JSON limit must be greater than zero")]
    ZeroJsonLimit,
    /// Per-session configuration cannot exceed the process hard bound.
    #[error("provider JSON limit {actual} exceeds hard limit {maximum}")]
    JsonLimitTooLarge {
        /// Supplied bound.
        actual: usize,
        /// Process hard bound.
        maximum: usize,
    },
    /// Every v2 frame needs its complete fixed header.
    #[error("provider binary limit {actual} is below fixed header size {required}")]
    BinaryLimitBelowHeader {
        /// Supplied bound.
        actual: usize,
        /// Exact v2 header size.
        required: usize,
    },
    /// Protocol ciphertext limit is the absolute maximum.
    #[error("provider binary limit {actual} exceeds protocol limit {maximum}")]
    BinaryLimitTooLarge {
        /// Supplied bound.
        actual: usize,
        /// Protocol hard bound.
        maximum: usize,
    },
}

/// Rejected registration or inbound provider frame.
#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum ProviderReadError {
    /// Text was rejected before typed allocation.
    #[error("provider JSON frame has {actual} bytes; maximum is {maximum}")]
    JsonTooLarge {
        /// Frame bytes.
        actual: usize,
        /// Configured bound.
        maximum: usize,
    },
    /// Binary header cannot be decoded from a shorter frame.
    #[error("provider binary frame has {actual} bytes; fixed header requires {required}")]
    BinaryHeaderTruncated {
        /// Frame bytes.
        actual: usize,
        /// Exact header bytes.
        required: usize,
    },
    /// Complete binary frame exceeded the configured or protocol bound.
    #[error("provider binary frame has {actual} bytes; maximum is {maximum}")]
    BinaryTooLarge {
        /// Frame bytes.
        actual: usize,
        /// Effective bound.
        maximum: usize,
    },
    /// Strict discriminator or typed JSON decode failed.
    #[error("malformed provider JSON: {0}")]
    MalformedJson(Arc<str>),
    /// Registration is the only legal first application frame.
    #[error("first provider application frame must be register, got {0:?}")]
    RegistrationRequired(Arc<str>),
    /// A second registration cannot mutate an active session.
    #[error("register is not valid after session activation")]
    DuplicateRegistration,
    /// Message belongs to a different negotiated major.
    #[error("message type {message_type:?} is invalid for negotiated protocol v{major}")]
    NegotiatedVersionViolation {
        /// Wire discriminator.
        message_type: Arc<str>,
        /// Negotiated major.
        major: u16,
    },
    /// Discriminator is not a committed provider-to-coordinator message.
    #[error("unknown provider message type {0:?}")]
    UnknownMessageType(Arc<str>),
    /// Nonterminal v2 control did not carry the exact current identity.
    #[error("provider control identity does not match the current session")]
    StaleControlIdentity,
    /// Durable terminal named another stable provider.
    #[error("historical provider terminal names a different stable provider")]
    TerminalProviderMismatch,
    /// A terminal cannot legitimately come from an epoch newer than its transport.
    #[error("provider terminal names a future session epoch")]
    FutureTerminalEpoch,
    /// Binary traffic is unavailable in v1.
    #[error("binary provider frame received without protocol-v2 negotiation")]
    BinaryNotNegotiated,
    /// Binary frame minor differs from the exact negotiated wire minor.
    #[error("provider binary minor {actual} does not match negotiated minor {expected}")]
    BinaryMinorMismatch {
        /// Header minor.
        actual: u16,
        /// Negotiated minor.
        expected: u16,
    },
    /// Binary identity must always be the exact current session.
    #[error("provider binary identity does not match the current session")]
    StaleBinaryIdentity,
    /// Fixed header or complete-frame protocol validation failed.
    #[error("invalid provider binary frame: {0}")]
    MalformedBinary(Arc<str>),
    /// Socket stream failed.
    #[error("provider WebSocket read failed: {0}")]
    Transport(Arc<str>),
    /// Downstream event processing stopped or the session was cancelled.
    #[error(transparent)]
    Event(#[from] SessionEventSendError),
    /// Registration read exceeded its handshake deadline.
    #[error("provider registration timed out after {0:?}")]
    RegistrationTimeout(Duration),
    /// Peer closed before registering.
    #[error("provider WebSocket closed before registration")]
    ClosedBeforeRegistration,
    /// Pilot integration did not release the post-ACK activation barrier.
    #[error("provider registration activation timed out after {0:?}")]
    ActivationTimeout(Duration),
    /// Pilot integration explicitly rejected this exact activated epoch.
    #[error("provider registration activation failed: {0}")]
    ActivationRejected(Arc<str>),
    /// The activation owner disappeared without resolving the barrier.
    #[error("provider registration activation owner became unavailable")]
    ActivationUnavailable,
}

#[derive(Deserialize)]
struct StrictTypeEnvelope<'a> {
    #[serde(borrow, rename = "type")]
    message_type: &'a str,
}

/// Parses one bounded first text frame while retaining exact signed values.
pub fn parse_registration_frame(
    wire: &[u8],
    config: ProviderReaderConfig,
) -> Result<RegistrationFrame, ProviderReadError> {
    let config = config
        .validate()
        .map_err(|error| ProviderReadError::MalformedJson(Arc::from(error.to_string())))?;
    ensure_json_bound(wire, config)?;
    let message_type = strict_message_type(wire)?;
    if message_type != "register" {
        return Err(ProviderReadError::RegistrationRequired(Arc::from(
            message_type,
        )));
    }
    let parsed = parse_provider_message(wire)
        .map_err(|error| ProviderReadError::MalformedJson(Arc::from(error.to_string())))?;
    let signed_attestation = parsed
        .signed_registration
        .attestation
        .map(ToOwned::to_owned);
    let signed_status = parsed.signed_registration.status.map(ToOwned::to_owned);
    let ProviderMessage::Register(registration) = parsed.message else {
        return Err(ProviderReadError::RegistrationRequired(Arc::from(
            message_type,
        )));
    };
    Ok(RegistrationFrame::new(
        registration,
        wire.to_vec(),
        signed_attestation,
        signed_status,
    ))
}

/// Waits for the first application text frame under one registration deadline.
pub async fn receive_registration<S, E>(
    stream: &mut S,
    config: ProviderReaderConfig,
    registration_timeout: Duration,
) -> Result<RegistrationFrame, ProviderReadError>
where
    S: Stream<Item = Result<Message, E>> + Unpin,
    E: fmt::Display,
{
    let receive = async {
        loop {
            match stream.next().await {
                Some(Ok(Message::Text(wire))) => {
                    return parse_registration_frame(wire.as_bytes(), config);
                }
                Some(Ok(Message::Ping(_) | Message::Pong(_))) => {}
                Some(Ok(Message::Binary(_))) => {
                    return Err(ProviderReadError::RegistrationRequired(Arc::from("binary")));
                }
                Some(Ok(Message::Close(_))) | None => {
                    return Err(ProviderReadError::ClosedBeforeRegistration);
                }
                Some(Err(error)) => {
                    return Err(ProviderReadError::Transport(Arc::from(error.to_string())));
                }
            }
        }
    };
    timeout(registration_timeout, receive)
        .await
        .map_err(|_| ProviderReadError::RegistrationTimeout(registration_timeout))?
}

/// Sole stream owner for one activated provider connection.
#[derive(Debug)]
pub struct ProviderReader {
    config: ProviderReaderConfig,
    identity: SessionIdentity,
    protocol: NegotiatedProtocol,
    events: SessionEventSender,
    cancellation: CancellationToken,
    activation: oneshot::Receiver<Result<(), Arc<str>>>,
    activation_timeout: Duration,
}

impl ProviderReader {
    /// Creates a strict reader after validating all bounds.
    pub fn new(
        config: ProviderReaderConfig,
        identity: SessionIdentity,
        protocol: NegotiatedProtocol,
        events: SessionEventSender,
        cancellation: CancellationToken,
        activation: oneshot::Receiver<Result<(), Arc<str>>>,
        activation_timeout: Duration,
    ) -> Result<Self, ProviderReaderConfigError> {
        Ok(Self {
            config: config.validate()?,
            identity,
            protocol,
            events,
            cancellation,
            activation,
            activation_timeout,
        })
    }

    /// Runs one and only one stream owner until peer close or cancellation.
    pub async fn run<S, E>(mut self, mut stream: S) -> Result<ProviderReaderExit, ProviderReadError>
    where
        S: Stream<Item = Result<Message, E>> + Unpin,
        E: fmt::Display,
    {
        let activation = tokio::select! {
            biased;
            () = self.cancellation.cancelled() => {
                return Ok(ProviderReaderExit::Cancelled);
            }
            result = timeout(self.activation_timeout, &mut self.activation) => result,
        };
        match activation {
            Ok(Ok(Ok(()))) => {}
            Ok(Ok(Err(reason))) => return Err(ProviderReadError::ActivationRejected(reason)),
            Ok(Err(_)) => return Err(ProviderReadError::ActivationUnavailable),
            Err(_) => {
                return Err(ProviderReadError::ActivationTimeout(
                    self.activation_timeout,
                ));
            }
        }

        loop {
            let next = tokio::select! {
                biased;
                () = self.cancellation.cancelled() => {
                    return Ok(ProviderReaderExit::Cancelled);
                }
                next = stream.next() => next,
            };
            let Some(next) = next else {
                return Ok(ProviderReaderExit::PeerClosed);
            };
            let message =
                next.map_err(|error| ProviderReadError::Transport(Arc::from(error.to_string())))?;
            let event = match message {
                Message::Text(wire) => Some(self.parse_text(wire.as_bytes())?),
                Message::Binary(wire) => Some(self.parse_binary(&wire)?),
                Message::Ping(_) | Message::Pong(_) => None,
                Message::Close(_) => return Ok(ProviderReaderExit::PeerClosed),
            };
            if let Some(event) = event {
                self.events.send(event, &self.cancellation).await?;
            }
        }
    }

    fn parse_text(&self, wire: &[u8]) -> Result<SessionEvent, ProviderReadError> {
        ensure_json_bound(wire, self.config)?;
        let message_type = strict_message_type(wire)?;
        if message_type == "register" {
            return Err(ProviderReadError::DuplicateRegistration);
        }

        match &self.protocol {
            NegotiatedProtocol::V1 => {
                if is_v2_control(message_type) {
                    return Err(ProviderReadError::NegotiatedVersionViolation {
                        message_type: Arc::from(message_type),
                        major: self.protocol.major(),
                    });
                }
                if !is_v1_provider(message_type) {
                    return Err(ProviderReadError::UnknownMessageType(Arc::from(
                        message_type,
                    )));
                }
                let parsed = parse_provider_message(wire).map_err(|error| {
                    ProviderReadError::MalformedJson(Arc::from(error.to_string()))
                })?;
                Ok(SessionEvent::V1 {
                    identity: self.identity,
                    message: Box::new(parsed.message),
                })
            }
            NegotiatedProtocol::V2(_) if is_v2_control(message_type) => {
                let message: ProviderControlMessage =
                    serde_json::from_slice(wire).map_err(|error| {
                        ProviderReadError::MalformedJson(Arc::from(error.to_string()))
                    })?;
                self.validate_control(&message)?;
                Ok(SessionEvent::V2Control {
                    identity: self.identity,
                    message: Box::new(message),
                })
            }
            NegotiatedProtocol::V2(_) if is_v2_common_v1(message_type) => {
                let parsed = parse_provider_message(wire).map_err(|error| {
                    ProviderReadError::MalformedJson(Arc::from(error.to_string()))
                })?;
                Ok(SessionEvent::V1 {
                    identity: self.identity,
                    message: Box::new(parsed.message),
                })
            }
            NegotiatedProtocol::V2(_) if is_v1_provider(message_type) => {
                Err(ProviderReadError::NegotiatedVersionViolation {
                    message_type: Arc::from(message_type),
                    major: self.protocol.major(),
                })
            }
            NegotiatedProtocol::V2(_) => Err(ProviderReadError::UnknownMessageType(Arc::from(
                message_type,
            ))),
        }
    }

    fn validate_control(&self, message: &ProviderControlMessage) -> Result<(), ProviderReadError> {
        match message {
            ProviderControlMessage::Terminal(terminal) => self.validate_terminal(terminal),
            ProviderControlMessage::Prepared(message) => self.validate_attempt(&message.identity),
            ProviderControlMessage::StartAck(message) => {
                if self.identity.matches_attempt(&message.identity)
                    || self.can_reconcile_historical_attempt(&message.identity)
                {
                    Ok(())
                } else {
                    Err(ProviderReadError::StaleControlIdentity)
                }
            }
            ProviderControlMessage::AttemptStatus(message) => {
                if !message.digest_shape_is_valid()
                    || message.identity.provider_id != self.identity.provider_id
                    || message.identity.session_epoch > self.identity.session_epoch
                {
                    Err(ProviderReadError::StaleControlIdentity)
                } else {
                    Ok(())
                }
            }
            ProviderControlMessage::AbortAck(message) => self.validate_attempt(&message.identity),
            ProviderControlMessage::CancelAck(message) => self.validate_attempt(&message.identity),
            ProviderControlMessage::StructuredError(message) => {
                self.validate_attempt(&message.identity)
            }
            ProviderControlMessage::ModelReady(message) => {
                if self.identity.matches_provider(&message.identity) {
                    Ok(())
                } else {
                    Err(ProviderReadError::StaleControlIdentity)
                }
            }
            ProviderControlMessage::ModelGone(message) => {
                if self.identity.matches_provider(&message.identity) {
                    Ok(())
                } else {
                    Err(ProviderReadError::StaleControlIdentity)
                }
            }
            ProviderControlMessage::ReplayFenceAck(message) => {
                // A current v2 connection may acknowledge a proof covering
                // tombstones from an older process generation. The stable
                // provider must match; the durable replay store binds the
                // proof ID to its exact historical generation.
                if message.provider_id == self.identity.provider_id {
                    Ok(())
                } else {
                    Err(ProviderReadError::StaleControlIdentity)
                }
            }
        }
    }

    fn validate_attempt(
        &self,
        identity: &darkbloom_coordinator_protocol::v2::AttemptIdentity,
    ) -> Result<(), ProviderReadError> {
        if self.identity.matches_attempt(identity) {
            Ok(())
        } else {
            Err(ProviderReadError::StaleControlIdentity)
        }
    }

    fn can_reconcile_historical_attempt(
        &self,
        identity: &darkbloom_coordinator_protocol::v2::AttemptIdentity,
    ) -> bool {
        matches!(
            &self.protocol,
            NegotiatedProtocol::V2(capabilities) if capabilities.attempt_reconciliation
        ) && identity.provider_id == self.identity.provider_id
            && identity.provider_process_generation == self.identity.provider_process_generation
            && identity.session_epoch <= self.identity.session_epoch
    }

    fn validate_terminal(&self, terminal: &ProviderTerminal) -> Result<(), ProviderReadError> {
        if terminal.identity.provider_id != self.identity.provider_id {
            return Err(ProviderReadError::TerminalProviderMismatch);
        }
        if terminal.identity.session_epoch > self.identity.session_epoch {
            return Err(ProviderReadError::FutureTerminalEpoch);
        }
        Ok(())
    }

    fn parse_binary(&self, wire: &[u8]) -> Result<SessionEvent, ProviderReadError> {
        let NegotiatedProtocol::V2(capabilities) = &self.protocol else {
            return Err(ProviderReadError::BinaryNotNegotiated);
        };
        if wire.len() < V2_BINARY_HEADER_LEN {
            return Err(ProviderReadError::BinaryHeaderTruncated {
                actual: wire.len(),
                required: V2_BINARY_HEADER_LEN,
            });
        }
        let effective_maximum = self
            .config
            .maximum_binary_bytes
            .min(MAX_V2_BINARY_FRAME_LEN);
        if wire.len() > effective_maximum {
            return Err(ProviderReadError::BinaryTooLarge {
                actual: wire.len(),
                maximum: effective_maximum,
            });
        }
        let frame = decode_binary_frame(wire)
            .map_err(|error| ProviderReadError::MalformedBinary(Arc::from(error.to_string())))?;
        if frame.header.minor != capabilities.protocol_minor {
            return Err(ProviderReadError::BinaryMinorMismatch {
                actual: frame.header.minor,
                expected: capabilities.protocol_minor,
            });
        }
        if frame.header.provider_id != self.identity.provider_id
            || frame.header.provider_process_generation != self.identity.provider_process_generation
            || frame.header.session_epoch != self.identity.session_epoch
        {
            return Err(ProviderReadError::StaleBinaryIdentity);
        }
        Ok(SessionEvent::V2Binary {
            identity: self.identity,
            frame: BinarySessionFrame {
                header: frame.header,
                ciphertext: frame.ciphertext.to_vec(),
            },
        })
    }
}

/// Clean reader termination reason.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProviderReaderExit {
    /// Peer closed or ended its stream.
    PeerClosed,
    /// Registry replacement or coordinated shutdown cancelled the session.
    Cancelled,
}

fn ensure_json_bound(wire: &[u8], config: ProviderReaderConfig) -> Result<(), ProviderReadError> {
    if wire.len() > config.maximum_json_bytes {
        return Err(ProviderReadError::JsonTooLarge {
            actual: wire.len(),
            maximum: config.maximum_json_bytes,
        });
    }
    Ok(())
}

fn strict_message_type(wire: &[u8]) -> Result<&str, ProviderReadError> {
    serde_json::from_slice::<StrictTypeEnvelope<'_>>(wire)
        .map(|envelope| envelope.message_type)
        .map_err(|error| ProviderReadError::MalformedJson(Arc::from(error.to_string())))
}

fn is_v1_provider(message_type: &str) -> bool {
    matches!(
        message_type,
        "heartbeat"
            | "inference_accepted"
            | "inference_response_chunk"
            | "inference_complete"
            | "inference_error"
            | "attestation_response"
            | "code_attestation_response"
            | "load_model_status"
            | "prefetch_model_status"
            | "models_update"
    )
}

fn is_v2_common_v1(message_type: &str) -> bool {
    matches!(
        message_type,
        "heartbeat"
            | "attestation_response"
            | "code_attestation_response"
            | "load_model_status"
            | "prefetch_model_status"
            | "models_update"
    )
}

fn is_v2_control(message_type: &str) -> bool {
    matches!(
        message_type,
        "prepared"
            | "start_ack"
            | "started"
            | "attempt_status"
            | "abort_ack"
            | "aborted"
            | "cancel_ack"
            | "cancelled"
            | "provider_terminal"
            | "structured_error"
            | "model_ready"
            | "model_gone"
            | "replay_fence_ack"
    )
}

#[cfg(test)]
mod tests {
    use darkbloom_coordinator_protocol::v2::{
        AbortAck, AttemptId, AttemptIdentity, AttemptStatus, AttemptStatusState, BinaryFrameFlags,
        BinaryFrameHeader, BinaryFrameKind, Digest, LeaseId, ProtocolCapabilities, ProviderId,
        ProviderProcessGenerationId, ProviderTerminal, ReplayFenceAck, ReplayFenceProofId,
        RequestId, ReservationId, SessionEpoch, StartAck, TerminalOutcome, TerminalSignature,
        encode_binary_frame,
    };

    use super::*;
    use crate::provider::types::session_event_channel;

    fn identity(epoch: u64) -> SessionIdentity {
        SessionIdentity {
            provider_id: ProviderId::new([1; 16]),
            provider_process_generation: ProviderProcessGenerationId::new([2; 16]),
            session_epoch: SessionEpoch(epoch),
        }
    }

    fn capabilities() -> ProtocolCapabilities {
        ProtocolCapabilities {
            protocol_major: 2,
            protocol_minor: 3,
            minimum_compatible_minor: 1,
            prepared_leases: true,
            start_authorization: true,
            structured_errors: true,
            start_ack: true,
            abort_ack: true,
            cancel_ack: true,
            durable_terminals: true,
            model_lifecycle_events: true,
            binary_payload_frames: true,
            coordinator_replay_fences: true,
            attempt_reconciliation: true,
        }
    }

    fn reader(protocol: NegotiatedProtocol) -> ProviderReader {
        let (events, _receiver) = session_event_channel(4).expect("channel");
        let (_activation, activation_wait) = oneshot::channel();
        ProviderReader::new(
            ProviderReaderConfig::default(),
            identity(7),
            protocol,
            events,
            CancellationToken::new(),
            activation_wait,
            Duration::from_secs(1),
        )
        .expect("reader")
    }

    fn attempt(epoch: u64, provider: u8) -> AttemptIdentity {
        AttemptIdentity {
            provider_id: ProviderId::new([provider; 16]),
            provider_process_generation: ProviderProcessGenerationId::new([2; 16]),
            session_epoch: SessionEpoch(epoch),
            request_id: RequestId::new([3; 16]),
            attempt_id: AttemptId::new([4; 16]),
            reservation_id: ReservationId::new([5; 16]),
            lease_id: LeaseId::new([6; 16]),
        }
    }

    fn terminal(epoch: u64, provider: u8) -> ProviderTerminal {
        let mut terminal = ProviderTerminal {
            identity: attempt(epoch, provider),
            outcome: TerminalOutcome::Completed,
            error_class: None,
            prompt_tokens: 1,
            completion_tokens: 1,
            reasoning_tokens: 0,
            response_hash: Digest::new([7; 32]),
            final_generated_tokens: 1,
            rolling_digest: Digest::new([8; 32]),
            model: "model".into(),
            terminal_digest: Digest::default(),
            signature: TerminalSignature::new(vec![1]),
        };
        terminal.terminal_digest = terminal.computed_digest().expect("digest");
        terminal
    }

    #[test]
    fn registration_preserves_raw_signed_values_exactly() {
        let wire = br#"{"type":"register","hardware":{"machine_model":"x","chip_name":"x","chip_family":"x","chip_tier":"x","memory_gb":1,"memory_available_gb":1,"cpu_cores":{"total":1,"performance":1,"efficiency":0},"gpu_cores":1,"memory_bandwidth_gbs":1},"models":[],"backend":"mlx","attestation": { "signature":"s", "attestation": { "z":1, "a":false } }}"#;
        let registration =
            parse_registration_frame(wire, ProviderReaderConfig::default()).expect("registration");
        assert_eq!(registration.wire(), wire);
        assert_eq!(
            registration.signed_attestation(),
            Some(&br#"{ "signature":"s", "attestation": { "z":1, "a":false } }"#[..])
        );
        assert_eq!(
            registration.signed_status(),
            Some(&br#"{ "z":1, "a":false }"#[..])
        );
    }

    #[test]
    fn duplicate_or_malformed_discriminator_is_rejected() {
        let malformed = br#"{"type":"heartbeat","type":"provider_terminal"}"#;
        assert!(matches!(
            reader(NegotiatedProtocol::V2(capabilities())).parse_text(malformed),
            Err(ProviderReadError::MalformedJson(_))
        ));
        assert!(matches!(
            reader(NegotiatedProtocol::V1).parse_text(br#"{"type":42}"#),
            Err(ProviderReadError::MalformedJson(_))
        ));
    }

    #[test]
    fn json_bound_is_checked_before_typed_decode() {
        let config = ProviderReaderConfig {
            maximum_json_bytes: 8,
            ..ProviderReaderConfig::default()
        };
        let (events, _receiver) = session_event_channel(1).expect("channel");
        let (_activation, activation_wait) = oneshot::channel();
        let reader = ProviderReader::new(
            config,
            identity(7),
            NegotiatedProtocol::V1,
            events,
            CancellationToken::new(),
            activation_wait,
            Duration::from_secs(1),
        )
        .expect("reader");
        assert!(matches!(
            reader.parse_text(br#"{"type":"heartbeat"}"#),
            Err(ProviderReadError::JsonTooLarge { maximum: 8, .. })
        ));
    }

    #[test]
    fn negotiated_major_rejects_cross_version_messages() {
        let prepared = serde_json::json!({
            "type": "prepared",
            "provider_id": identity(7).provider_id,
            "provider_process_generation": identity(7).provider_process_generation,
            "session_epoch": 7,
            "request_id": RequestId::new([3; 16]),
            "attempt_id": AttemptId::new([4; 16]),
            "reservation_id": ReservationId::new([5; 16]),
            "lease_id": LeaseId::new([6; 16]),
            "model": "m",
            "request_digest": Digest::new([0; 32]),
            "lease_ttl_ms": 1,
            "prompt_tokens": 1,
            "max_output_tokens": 1,
            "engine_queue_depth": 0,
            "reserved_kv_bytes": 0,
            "reserved_media_bytes": 0,
            "prefill_can_begin": true
        });
        assert!(matches!(
            reader(NegotiatedProtocol::V1)
                .parse_text(&serde_json::to_vec(&prepared).expect("JSON")),
            Err(ProviderReadError::NegotiatedVersionViolation { major: 1, .. })
        ));
        assert!(matches!(
            reader(NegotiatedProtocol::V2(capabilities())).parse_text(
                br#"{"type":"inference_complete","request_id":"x","prompt_tokens":0,"completion_tokens":0}"#
            ),
            Err(ProviderReadError::NegotiatedVersionViolation { major: 2, .. })
        ));
    }

    #[test]
    fn historical_terminal_for_same_provider_is_accepted() {
        let wire = serde_json::to_vec(&ProviderControlMessage::Terminal(terminal(3, 1)))
            .expect("terminal JSON");
        let event = reader(NegotiatedProtocol::V2(capabilities()))
            .parse_text(&wire)
            .expect("historical terminal");
        let SessionEvent::V2Control { message, .. } = event else {
            panic!("v2 control");
        };
        assert!(matches!(*message, ProviderControlMessage::Terminal(_)));
    }

    #[test]
    fn historical_attempt_status_is_classified_and_shape_checked() {
        let status = ProviderControlMessage::AttemptStatus(AttemptStatus {
            identity: attempt(3, 1),
            state: AttemptStatusState::Started,
            terminal_digest: None,
        });
        let wire = serde_json::to_vec(&status).expect("attempt status JSON");
        assert!(matches!(
            reader(NegotiatedProtocol::V2(capabilities())).parse_text(&wire),
            Ok(SessionEvent::V2Control { .. })
        ));

        let invalid = ProviderControlMessage::AttemptStatus(AttemptStatus {
            identity: attempt(3, 1),
            state: AttemptStatusState::Terminal,
            terminal_digest: None,
        });
        let wire = serde_json::to_vec(&invalid).expect("invalid attempt status JSON");
        assert_eq!(
            reader(NegotiatedProtocol::V2(capabilities()))
                .parse_text(&wire)
                .expect_err("missing terminal digest"),
            ProviderReadError::StaleControlIdentity
        );
    }

    #[test]
    fn historical_start_ack_is_accepted_only_from_same_process_reconnect() {
        let historical = ProviderControlMessage::StartAck(StartAck {
            identity: attempt(6, 1),
        });
        let wire = serde_json::to_vec(&historical).expect("historical StartAck JSON");
        assert!(matches!(
            reader(NegotiatedProtocol::V2(capabilities())).parse_text(&wire),
            Ok(SessionEvent::V2Control { .. })
        ));

        let mut foreign_process = attempt(6, 1);
        foreign_process.provider_process_generation = ProviderProcessGenerationId::new([9; 16]);
        let wire = serde_json::to_vec(&ProviderControlMessage::StartAck(StartAck {
            identity: foreign_process,
        }))
        .expect("foreign StartAck JSON");
        assert_eq!(
            reader(NegotiatedProtocol::V2(capabilities()))
                .parse_text(&wire)
                .expect_err("foreign process generation"),
            ProviderReadError::StaleControlIdentity
        );

        let mut without_reconciliation = capabilities();
        without_reconciliation.attempt_reconciliation = false;
        let wire = serde_json::to_vec(&historical).expect("historical StartAck JSON");
        assert_eq!(
            reader(NegotiatedProtocol::V2(without_reconciliation))
                .parse_text(&wire)
                .expect_err("historical StartAck without reconciliation"),
            ProviderReadError::StaleControlIdentity
        );
    }

    #[test]
    fn terminal_from_other_provider_or_future_epoch_is_rejected() {
        for (terminal, expected) in [
            (terminal(3, 9), ProviderReadError::TerminalProviderMismatch),
            (terminal(8, 1), ProviderReadError::FutureTerminalEpoch),
        ] {
            let wire =
                serde_json::to_vec(&ProviderControlMessage::Terminal(terminal)).expect("JSON");
            assert_eq!(
                reader(NegotiatedProtocol::V2(capabilities()))
                    .parse_text(&wire)
                    .expect_err("rejected"),
                expected
            );
        }
    }

    #[test]
    fn non_reconciliation_v2_control_requires_current_identity() {
        let message = ProviderControlMessage::AbortAck(AbortAck {
            identity: attempt(6, 1),
        });
        let wire = serde_json::to_vec(&message).expect("JSON");
        assert_eq!(
            reader(NegotiatedProtocol::V2(capabilities()))
                .parse_text(&wire)
                .expect_err("stale"),
            ProviderReadError::StaleControlIdentity
        );
    }

    #[test]
    fn replay_ack_accepts_historical_generation_for_current_stable_provider() {
        let message = ProviderControlMessage::ReplayFenceAck(ReplayFenceAck {
            proof_id: ReplayFenceProofId::new([9; 16]),
            provider_id: identity(7).provider_id,
            provider_process_generation: ProviderProcessGenerationId::new([8; 16]),
        });
        let wire = serde_json::to_vec(&message).expect("JSON");
        assert!(matches!(
            reader(NegotiatedProtocol::V2(capabilities())).parse_text(&wire),
            Ok(SessionEvent::V2Control { .. })
        ));
    }

    #[test]
    fn binary_requires_exact_header_minor_identity_and_total_length() {
        let mut header = BinaryFrameHeader {
            kind: BinaryFrameKind::ResponseChunk,
            flags: BinaryFrameFlags::EMPTY,
            minor: 3,
            provider_id: identity(7).provider_id,
            provider_process_generation: identity(7).provider_process_generation,
            session_epoch: SessionEpoch(7),
            request_id: RequestId::new([3; 16]),
            attempt_id: AttemptId::new([4; 16]),
            reservation_id: ReservationId::new([5; 16]),
            lease_id: LeaseId::new([6; 16]),
            nonce: [0; 24],
            rolling_digest: [0; 32],
            sequence: 1,
            ciphertext_len: 3,
            cumulative_tokens: 1,
        };
        let reader = reader(NegotiatedProtocol::V2(capabilities()));
        let valid = encode_binary_frame(&header, b"abc").expect("frame");
        assert!(matches!(
            reader.parse_binary(&valid),
            Ok(SessionEvent::V2Binary { .. })
        ));
        assert!(matches!(
            reader.parse_binary(&valid[..V2_BINARY_HEADER_LEN - 1]),
            Err(ProviderReadError::BinaryHeaderTruncated { .. })
        ));

        header.minor = 2;
        let wrong_minor = encode_binary_frame(&header, b"abc").expect("frame");
        assert!(matches!(
            reader.parse_binary(&wrong_minor),
            Err(ProviderReadError::BinaryMinorMismatch { .. })
        ));
        header.minor = 3;
        header.session_epoch = SessionEpoch(6);
        let stale = encode_binary_frame(&header, b"abc").expect("frame");
        assert_eq!(
            reader.parse_binary(&stale).expect_err("stale"),
            ProviderReadError::StaleBinaryIdentity
        );
    }
}
