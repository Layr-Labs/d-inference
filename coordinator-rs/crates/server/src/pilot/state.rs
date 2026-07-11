use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use darkbloom_coordinator_core::{ids::ProviderId as CoreProviderId, request::ProviderFence};
use darkbloom_coordinator_protocol::v2::{
    AttemptIdentity, BinaryFrameHeader, Digest, ProviderId, ProviderProcessGenerationId, RequestId,
};
use thiserror::Error;
use uuid::Uuid;

use crate::{
    crypto::{ProviderRequestSeal, X25519PublicKey},
    provider::{NegotiatedProtocol, ProviderWriterHandle, SessionIdentity},
    request::{BytePipeSender, CancellationReason, InboundAttemptEvent, RequestCancellation},
    trust::{P256PublicIdentity, verify_signature},
};

/// Immutable request-routing view of one authenticated current session.
#[derive(Clone)]
pub struct PilotSession {
    pub identity: SessionIdentity,
    pub protocol: NegotiatedProtocol,
    pub writer: ProviderWriterHandle,
    pub provider_key: X25519PublicKey,
    pub signing_key: P256PublicIdentity,
    pub fence: ProviderFence,
    pub control_only: bool,
    pub model_eligible: bool,
}

impl PilotSession {
    #[must_use]
    pub fn is_v2(&self) -> bool {
        matches!(self.protocol, NegotiatedProtocol::V2(_))
    }

    #[must_use]
    pub fn v2_minor(&self) -> Option<u16> {
        self.protocol.v2_minor()
    }

    #[must_use]
    pub fn verifies_terminal(
        &self,
        provider_id: ProviderId,
        generation: ProviderProcessGenerationId,
        digest: &Digest,
        signature: &[u8],
    ) -> bool {
        if provider_id != self.identity.provider_id
            || generation != self.identity.provider_process_generation
        {
            return false;
        }
        verify_signature(
            &self.signing_key,
            &STANDARD.encode(signature),
            digest.as_bytes(),
        )
        .is_ok()
    }
}

#[derive(Default)]
struct DirectoryState {
    sessions: BTreeMap<ProviderId, PilotSession>,
    signing_keys: BTreeMap<(ProviderId, ProviderProcessGenerationId), P256PublicIdentity>,
    heartbeat_sequences: BTreeMap<ProviderId, u64>,
    unknown_current_terminals: BTreeMap<ProviderId, usize>,
}

/// Linearizable current-session view used after Fleet admission.
pub struct SessionDirectory {
    maximum_signing_keys: usize,
    state: Mutex<DirectoryState>,
}

impl SessionDirectory {
    #[must_use]
    pub fn new(maximum_signing_keys: usize) -> Self {
        assert!(maximum_signing_keys > 0);
        Self {
            maximum_signing_keys,
            state: Mutex::new(DirectoryState::default()),
        }
    }

    pub fn install(&self, session: PilotSession) -> Option<PilotSession> {
        let provider_id = session.identity.provider_id;
        let mut state = self.lock();
        let signing_key = (provider_id, session.identity.provider_process_generation);
        if !state.signing_keys.contains_key(&signing_key)
            && state.signing_keys.len() == self.maximum_signing_keys
            && let Some(oldest) = state.signing_keys.keys().next().copied()
        {
            state.signing_keys.remove(&oldest);
        }
        state
            .signing_keys
            .insert(signing_key, session.signing_key.clone());
        state.heartbeat_sequences.insert(provider_id, 0);
        state.unknown_current_terminals.remove(&provider_id);
        state.sessions.insert(provider_id, session)
    }

    #[must_use]
    pub fn current(&self, provider_id: ProviderId) -> Option<PilotSession> {
        self.lock().sessions.get(&provider_id).cloned()
    }

    #[must_use]
    pub fn inference_session(&self, fence: &ProviderFence) -> Option<PilotSession> {
        let provider_id = wire_provider_id(fence.provider_id);
        self.lock()
            .sessions
            .get(&provider_id)
            .filter(|session| {
                session.is_v2()
                    && !session.control_only
                    && session.model_eligible
                    && session.fence == *fence
            })
            .cloned()
    }

    pub fn remove_if_current(&self, identity: SessionIdentity) -> Option<PilotSession> {
        let mut state = self.lock();
        if state
            .sessions
            .get(&identity.provider_id)
            .is_none_or(|session| session.identity != identity)
        {
            return None;
        }
        state
            .unknown_current_terminals
            .remove(&identity.provider_id);
        state.heartbeat_sequences.remove(&identity.provider_id);
        state.sessions.remove(&identity.provider_id)
    }

    pub fn promote_if_current(&self, identity: SessionIdentity) -> Option<PilotSession> {
        let mut state = self.lock();
        let session = state.sessions.get_mut(&identity.provider_id)?;
        if session.identity != identity {
            return None;
        }
        session.control_only = !session.model_eligible;
        Some(session.clone())
    }

    pub fn fence_if_current(
        &self,
        identity: SessionIdentity,
        reason: &'static str,
    ) -> Option<SessionIdentity> {
        let mut state = self.lock();
        let session = state.sessions.get_mut(&identity.provider_id)?;
        if session.identity != identity {
            return None;
        }
        session.control_only = true;
        session.writer.fence(Arc::from(reason));
        Some(identity)
    }

    /// Counts an unrecognized terminal for the current transport and returns
    /// true at the configured provider-local fencing threshold.
    pub fn record_unknown_terminal(&self, identity: SessionIdentity, maximum: usize) -> bool {
        let mut state = self.lock();
        if state
            .sessions
            .get(&identity.provider_id)
            .is_none_or(|session| session.identity != identity)
        {
            return false;
        }
        let count = state
            .unknown_current_terminals
            .entry(identity.provider_id)
            .or_default();
        *count = count.saturating_add(1);
        *count >= maximum
    }

    /// Advances the Fleet heartbeat sequence only for the exact current
    /// transport. The sequence is local to the session revision and starts at
    /// one, matching Fleet's stale-report contract.
    pub fn next_heartbeat_sequence(&self, identity: SessionIdentity) -> Option<u64> {
        let mut state = self.lock();
        if state
            .sessions
            .get(&identity.provider_id)
            .is_none_or(|session| session.identity != identity)
        {
            return None;
        }
        let sequence = state
            .heartbeat_sequences
            .entry(identity.provider_id)
            .or_default();
        *sequence = sequence.checked_add(1)?;
        Some(*sequence)
    }

    #[must_use]
    pub fn verifies_terminal(
        &self,
        provider_id: ProviderId,
        generation: ProviderProcessGenerationId,
        digest: &Digest,
        signature: &[u8],
    ) -> bool {
        let state = self.lock();
        let Some(key) = state.signing_keys.get(&(provider_id, generation)) else {
            return false;
        };
        verify_signature(key, &STANDARD.encode(signature), digest.as_bytes()).is_ok()
    }

    #[must_use]
    pub fn visible_count(&self) -> usize {
        self.lock().sessions.len()
    }

    #[must_use]
    pub fn inference_count(&self) -> usize {
        self.lock()
            .sessions
            .values()
            .filter(|session| session.is_v2() && !session.control_only && session.model_eligible)
            .count()
    }

    #[must_use]
    pub fn sessions(&self) -> Vec<PilotSession> {
        self.lock().sessions.values().cloned().collect()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, DirectoryState> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

impl Default for SessionDirectory {
    fn default() -> Self {
        Self::new(4_096)
    }
}

struct RequestRoute {
    inbound: BytePipeSender<InboundAttemptEvent>,
    seal: Arc<ProviderRequestSeal>,
    provider_key: X25519PublicKey,
    session_identity: SessionIdentity,
    attempt_identity: AttemptIdentity,
    cancellation: RequestCancellation,
}

pub(crate) struct RequestRouteRegistration {
    pub request_id: RequestId,
    pub inbound: BytePipeSender<InboundAttemptEvent>,
    pub seal: Arc<ProviderRequestSeal>,
    pub provider_key: X25519PublicKey,
    pub session_identity: SessionIdentity,
    pub attempt_identity: AttemptIdentity,
    pub cancellation: RequestCancellation,
}

struct RequestTableState {
    routes: BTreeMap<RequestId, RequestRoute>,
}

/// Bounded sole routing table for direct provider events.
pub struct RequestTable {
    maximum: usize,
    state: Mutex<RequestTableState>,
}

impl RequestTable {
    #[must_use]
    pub fn new(maximum: usize) -> Self {
        assert!(maximum > 0);
        Self {
            maximum,
            state: Mutex::new(RequestTableState {
                routes: BTreeMap::new(),
            }),
        }
    }

    pub(crate) fn insert(
        self: &Arc<Self>,
        registration: RequestRouteRegistration,
    ) -> Result<RequestRegistration, RequestTableError> {
        let RequestRouteRegistration {
            request_id,
            inbound,
            seal,
            provider_key,
            session_identity,
            attempt_identity,
            cancellation,
        } = registration;
        if attempt_identity.request_id != request_id
            || !session_identity.matches_attempt(&attempt_identity)
        {
            return Err(RequestTableError::IdentityMismatch);
        }
        let mut state = self.lock();
        if state.routes.contains_key(&request_id) {
            return Err(RequestTableError::Duplicate);
        }
        if state.routes.len() == self.maximum {
            return Err(RequestTableError::Full {
                maximum: self.maximum,
            });
        }
        state.routes.insert(
            request_id,
            RequestRoute {
                inbound,
                seal,
                provider_key,
                session_identity,
                attempt_identity,
                cancellation,
            },
        );
        Ok(RequestRegistration {
            table: self.clone(),
            request_id,
            active: true,
        })
    }

    pub fn route(
        &self,
        identity: &AttemptIdentity,
        event: InboundAttemptEvent,
    ) -> Result<(), RequestRouteError> {
        let state = self.lock();
        let route = state
            .routes
            .get(&identity.request_id)
            .ok_or(RequestRouteError::Unknown)?;
        if route.attempt_identity != *identity {
            return Err(RequestRouteError::Stale);
        }
        route
            .inbound
            .try_send(event)
            .map_err(|error| RequestRouteError::Closed(Arc::from(error.to_string())))
    }

    pub fn open_binary(
        &self,
        header: &BinaryFrameHeader,
        ciphertext: &[u8],
    ) -> Result<Vec<u8>, RequestRouteError> {
        let state = self.lock();
        let route = state
            .routes
            .get(&header.request_id)
            .ok_or(RequestRouteError::Unknown)?;
        if !header_matches_attempt(header, &route.attempt_identity) {
            return Err(RequestRouteError::Stale);
        }
        route
            .seal
            .open_response(route.provider_key, header, ciphertext)
            .map_err(|error| RequestRouteError::Authentication(Arc::from(error.to_string())))
    }

    pub fn cancel_session(&self, identity: SessionIdentity) {
        let cancellations: Vec<_> = self
            .lock()
            .routes
            .values()
            .filter(|route| route.session_identity == identity)
            .map(|route| route.cancellation.clone())
            .collect();
        for cancellation in cancellations {
            cancellation.cancel(CancellationReason::RequestEnded);
        }
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.lock().routes.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.lock().routes.is_empty()
    }

    fn remove(&self, request_id: RequestId) -> Option<RequestRoute> {
        self.lock().routes.remove(&request_id)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, RequestTableState> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

/// RAII table ownership installed before any provider operation.
pub struct RequestRegistration {
    table: Arc<RequestTable>,
    request_id: RequestId,
    active: bool,
}

impl RequestRegistration {
    pub fn replace_attempt(
        &self,
        seal: Arc<ProviderRequestSeal>,
        provider_key: X25519PublicKey,
        session_identity: SessionIdentity,
        attempt_identity: AttemptIdentity,
    ) -> Result<(), RequestTableError> {
        if attempt_identity.request_id != self.request_id
            || !session_identity.matches_attempt(&attempt_identity)
        {
            return Err(RequestTableError::IdentityMismatch);
        }
        let mut state = self.table.lock();
        let route = state
            .routes
            .get_mut(&self.request_id)
            .ok_or(RequestTableError::Missing)?;
        route.seal = seal;
        route.provider_key = provider_key;
        route.session_identity = session_identity;
        route.attempt_identity = attempt_identity;
        Ok(())
    }

    pub fn remove(mut self) {
        let _ = self.table.remove(self.request_id);
        self.active = false;
    }
}

impl Drop for RequestRegistration {
    fn drop(&mut self) {
        if self.active
            && let Some(route) = self.table.remove(self.request_id)
        {
            route.cancellation.cancel(CancellationReason::RequestEnded);
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum RequestTableError {
    #[error("request routing table already contains this request")]
    Duplicate,
    #[error("request routing table limit of {maximum} reached")]
    Full { maximum: usize },
    #[error("request routing identity is inconsistent")]
    IdentityMismatch,
    #[error("request routing table entry is missing")]
    Missing,
}

#[derive(Clone, Debug, Eq, Error, PartialEq)]
pub enum RequestRouteError {
    #[error("request is not active")]
    Unknown,
    #[error("provider event belongs to a superseded request attempt")]
    Stale,
    #[error("request event lane is closed: {0}")]
    Closed(Arc<str>),
    #[error("provider response authentication failed: {0}")]
    Authentication(Arc<str>),
}

#[must_use]
pub fn wire_provider_id(provider_id: CoreProviderId) -> ProviderId {
    ProviderId::new(*provider_id.as_uuid().as_bytes())
}

pub fn core_provider_id(provider_id: ProviderId) -> CoreProviderId {
    CoreProviderId::new(Uuid::from_bytes(provider_id.into_bytes()))
        .expect("wire provider identity is nonzero")
}

fn header_matches_attempt(header: &BinaryFrameHeader, identity: &AttemptIdentity) -> bool {
    header.provider_id == identity.provider_id
        && header.provider_process_generation == identity.provider_process_generation
        && header.session_epoch == identity.session_epoch
        && header.request_id == identity.request_id
        && header.attempt_id == identity.attempt_id
        && header.reservation_id == identity.reservation_id
        && header.lease_id == identity.lease_id
}
