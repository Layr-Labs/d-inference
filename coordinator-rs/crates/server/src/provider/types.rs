//! Provider-session identities, owned inbound events, and their bounded lane.

use std::sync::Arc;

use darkbloom_coordinator_protocol::{
    v1::{ProviderMessage, Registration},
    v2::{
        AttemptIdentity, BinaryFrameHeader, ProtocolCapabilities, ProviderControlMessage,
        ProviderId, ProviderProcessGenerationId, ProviderSessionIdentity, SessionEpoch,
    },
};
use thiserror::Error;
use tokio::sync::{mpsc, oneshot};
use tokio_util::sync::CancellationToken;

/// Hard upper bound for one session's downstream event lane.
pub const MAX_SESSION_EVENT_CAPACITY: usize = 65_536;

/// Exact identity of one accepted provider WebSocket session.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct SessionIdentity {
    /// Stable provider identity, unchanged across reconnects.
    pub provider_id: ProviderId,
    /// Provider process generation advertised (or assigned for legacy v1).
    pub provider_process_generation: ProviderProcessGenerationId,
    /// Monotonic WebSocket epoch for this stable provider.
    pub session_epoch: SessionEpoch,
}

impl SessionIdentity {
    /// Returns whether every provider-session component of an attempt is current.
    #[must_use]
    pub fn matches_attempt(&self, identity: &AttemptIdentity) -> bool {
        self.provider_id == identity.provider_id
            && self.provider_process_generation == identity.provider_process_generation
            && self.session_epoch.0 == identity.session_epoch.0
    }

    /// Returns whether a provider-scoped control carries this exact session.
    #[must_use]
    pub fn matches_provider(&self, identity: &ProviderSessionIdentity) -> bool {
        self.provider_id == identity.provider_id
            && self.provider_process_generation == identity.process_generation
            && self.session_epoch.0 == identity.session_epoch.0
    }
}

/// Explicit result of registration capability negotiation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum NegotiatedProtocol {
    /// Deployed JSON protocol.
    V1,
    /// Complete protocol-v2 feature set and negotiated minor range.
    V2(ProtocolCapabilities),
}

impl NegotiatedProtocol {
    /// Returns the negotiated major version.
    #[must_use]
    pub const fn major(&self) -> u16 {
        match self {
            Self::V1 => darkbloom_coordinator_protocol::PROTOCOL_V1_MAJOR,
            Self::V2(_) => darkbloom_coordinator_protocol::PROTOCOL_V2_MAJOR,
        }
    }

    /// Returns the exact v2 minor carried by binary frames.
    #[must_use]
    pub const fn v2_minor(&self) -> Option<u16> {
        match self {
            Self::V1 => None,
            Self::V2(capabilities) => Some(capabilities.protocol_minor),
        }
    }
}

/// Registration plus exact signed slices copied from the original wire bytes.
///
/// Typed registration is shared rather than cloned, and both signed values are
/// copied byte-for-byte before the parser's borrow of the WebSocket frame ends.
#[derive(Clone, Debug)]
pub struct RegistrationFrame {
    registration: Arc<Registration>,
    wire: Arc<[u8]>,
    signed_attestation: Option<Arc<[u8]>>,
    signed_status: Option<Arc<[u8]>>,
}

impl RegistrationFrame {
    pub(crate) fn new(
        registration: Registration,
        wire: Vec<u8>,
        signed_attestation: Option<Vec<u8>>,
        signed_status: Option<Vec<u8>>,
    ) -> Self {
        Self {
            registration: Arc::new(registration),
            wire: wire.into(),
            signed_attestation: signed_attestation.map(Into::into),
            signed_status: signed_status.map(Into::into),
        }
    }

    /// Returns the typed registration.
    #[must_use]
    pub fn registration(&self) -> &Registration {
        &self.registration
    }

    /// Returns the complete original JSON frame.
    #[must_use]
    pub fn wire(&self) -> &[u8] {
        &self.wire
    }

    /// Returns the exact signed outer attestation JSON value.
    #[must_use]
    pub fn signed_attestation(&self) -> Option<&[u8]> {
        self.signed_attestation.as_deref()
    }

    /// Returns the exact nested status JSON value covered by the signature.
    #[must_use]
    pub fn signed_status(&self) -> Option<&[u8]> {
        self.signed_status.as_deref()
    }
}

/// Owned and validated protocol-v2 binary frame.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BinarySessionFrame {
    /// Validated fixed-width header.
    pub header: BinaryFrameHeader,
    /// Exact authenticated ciphertext bytes.
    pub ciphertext: Vec<u8>,
}

/// Concrete messages emitted by a provider reader.
#[derive(Debug)]
pub enum SessionEvent {
    /// Registration became the registry's current session.
    Registered {
        /// Current identity.
        identity: SessionIdentity,
        /// Explicit negotiated wire version.
        protocol: NegotiatedProtocol,
        /// Typed registration and exact signed bytes.
        registration: RegistrationFrame,
        /// One-shot barrier released only after pilot integration for this
        /// exact epoch is fully installed.
        activation: oneshot::Sender<Result<(), Arc<str>>>,
    },
    /// Accepted protocol-v1 provider message.
    V1 {
        /// Session on which the unscoped v1 message arrived.
        identity: SessionIdentity,
        /// Typed message.
        message: Box<ProviderMessage>,
    },
    /// Accepted protocol-v2 control message.
    V2Control {
        /// Current transport session. A durable terminal can itself name a
        /// historical epoch for the same stable provider.
        identity: SessionIdentity,
        /// Typed control.
        message: Box<ProviderControlMessage>,
    },
    /// Accepted protocol-v2 encrypted payload frame.
    V2Binary {
        /// Current transport session.
        identity: SessionIdentity,
        /// Validated frame.
        frame: BinarySessionFrame,
    },
}

/// Invalid concrete event-channel bound.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum SessionEventChannelConfigError {
    /// Tokio bounded channels require at least one slot.
    #[error("session event channel capacity must be greater than zero")]
    ZeroCapacity,
    /// A caller cannot accidentally turn a per-session lane into a huge buffer.
    #[error("session event channel capacity {actual} exceeds hard limit {maximum}")]
    CapacityTooLarge {
        /// Supplied capacity.
        actual: usize,
        /// Hard maximum.
        maximum: usize,
    },
}

/// Failure to publish one validated session event.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum SessionEventSendError {
    /// Session cancellation won before downstream accepted the event.
    #[error("provider session was cancelled")]
    Cancelled,
    /// The sole event consumer has exited.
    #[error("provider session event consumer is unavailable")]
    ConsumerUnavailable,
    /// Nonblocking publication found the bounded lane full.
    #[error("provider session event channel is full")]
    Full,
}

/// Cloneable producer for the concrete bounded session-event lane.
#[derive(Clone, Debug)]
pub struct SessionEventSender {
    inner: mpsc::Sender<SessionEvent>,
}

impl SessionEventSender {
    /// Publishes with bounded backpressure and cancellation.
    pub async fn send(
        &self,
        event: SessionEvent,
        cancellation: &CancellationToken,
    ) -> Result<(), SessionEventSendError> {
        tokio::select! {
            biased;
            () = cancellation.cancelled() => Err(SessionEventSendError::Cancelled),
            result = self.inner.send(event) => {
                result.map_err(|_| SessionEventSendError::ConsumerUnavailable)
            }
        }
    }

    /// Attempts immediate publication without waiting for capacity.
    pub fn try_send(&self, event: SessionEvent) -> Result<(), SessionEventSendError> {
        self.inner.try_send(event).map_err(|error| match error {
            mpsc::error::TrySendError::Full(_) => SessionEventSendError::Full,
            mpsc::error::TrySendError::Closed(_) => SessionEventSendError::ConsumerUnavailable,
        })
    }

    /// Returns currently unused event slots.
    #[must_use]
    pub fn remaining_capacity(&self) -> usize {
        self.inner.capacity()
    }
}

/// Sole consumer for the concrete bounded session-event lane.
#[derive(Debug)]
pub struct SessionEventReceiver {
    inner: mpsc::Receiver<SessionEvent>,
}

impl SessionEventReceiver {
    /// Receives the next event, or `None` after every producer is gone.
    pub async fn recv(&mut self) -> Option<SessionEvent> {
        self.inner.recv().await
    }

    /// Returns the number of queued events.
    #[must_use]
    pub fn len(&self) -> usize {
        self.inner.len()
    }

    /// Returns whether no events are queued.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.inner.is_empty()
    }
}

/// Creates one finite per-session event lane.
pub fn session_event_channel(
    capacity: usize,
) -> Result<(SessionEventSender, SessionEventReceiver), SessionEventChannelConfigError> {
    if capacity == 0 {
        return Err(SessionEventChannelConfigError::ZeroCapacity);
    }
    if capacity > MAX_SESSION_EVENT_CAPACITY {
        return Err(SessionEventChannelConfigError::CapacityTooLarge {
            actual: capacity,
            maximum: MAX_SESSION_EVENT_CAPACITY,
        });
    }
    let (sender, receiver) = mpsc::channel(capacity);
    Ok((
        SessionEventSender { inner: sender },
        SessionEventReceiver { inner: receiver },
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity(epoch: u64) -> SessionIdentity {
        SessionIdentity {
            provider_id: ProviderId::new([1; 16]),
            provider_process_generation: ProviderProcessGenerationId::new([2; 16]),
            session_epoch: SessionEpoch(epoch),
        }
    }

    #[test]
    fn exact_identity_matches_attempt_and_provider_fences() {
        let current = identity(7);
        let attempt = AttemptIdentity {
            provider_id: current.provider_id,
            provider_process_generation: current.provider_process_generation,
            session_epoch: current.session_epoch,
            request_id: darkbloom_coordinator_protocol::v2::RequestId::new([3; 16]),
            attempt_id: darkbloom_coordinator_protocol::v2::AttemptId::new([4; 16]),
            reservation_id: darkbloom_coordinator_protocol::v2::ReservationId::new([5; 16]),
            lease_id: darkbloom_coordinator_protocol::v2::LeaseId::new([6; 16]),
        };
        assert!(current.matches_attempt(&attempt));
        assert!(current.matches_provider(&ProviderSessionIdentity {
            provider_id: current.provider_id,
            process_generation: current.provider_process_generation,
            session_epoch: current.session_epoch,
        }));

        let mut stale = attempt;
        stale.session_epoch = SessionEpoch(6);
        assert!(!current.matches_attempt(&stale));
    }

    #[test]
    fn event_channel_rejects_unbounded_shapes() {
        assert!(matches!(
            session_event_channel(0),
            Err(SessionEventChannelConfigError::ZeroCapacity)
        ));
        assert!(matches!(
            session_event_channel(MAX_SESSION_EVENT_CAPACITY + 1),
            Err(SessionEventChannelConfigError::CapacityTooLarge { .. })
        ));
    }

    #[test]
    fn event_channel_has_concrete_backpressure() {
        let (sender, receiver) = session_event_channel(1).expect("bounded channel");
        sender
            .try_send(SessionEvent::V2Binary {
                identity: identity(1),
                frame: BinarySessionFrame {
                    header: test_header(),
                    ciphertext: Vec::new(),
                },
            })
            .expect("first event");
        assert_eq!(receiver.len(), 1);
        assert!(matches!(
            sender.try_send(SessionEvent::V2Binary {
                identity: identity(1),
                frame: BinarySessionFrame {
                    header: test_header(),
                    ciphertext: Vec::new(),
                },
            }),
            Err(SessionEventSendError::Full)
        ));
    }

    fn test_header() -> BinaryFrameHeader {
        use darkbloom_coordinator_protocol::v2::{
            AttemptId, BinaryFrameFlags, BinaryFrameKind, LeaseId, RequestId, ReservationId,
        };

        BinaryFrameHeader {
            kind: BinaryFrameKind::ResponseChunk,
            flags: BinaryFrameFlags::EMPTY,
            minor: 0,
            provider_id: ProviderId::new([1; 16]),
            provider_process_generation: ProviderProcessGenerationId::new([2; 16]),
            session_epoch: SessionEpoch(1),
            request_id: RequestId::new([3; 16]),
            attempt_id: AttemptId::new([4; 16]),
            reservation_id: ReservationId::new([5; 16]),
            lease_id: LeaseId::new([6; 16]),
            nonce: [0; 24],
            rolling_digest: [0; 32],
            sequence: 0,
            ciphertext_len: 0,
            cumulative_tokens: 0,
        }
    }
}
