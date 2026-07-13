use std::{
    collections::{BTreeMap, BTreeSet, VecDeque},
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use axum::extract::ws::{Message, WebSocket};
use base64::Engine as _;
use darkbloom_coordinator_core::{
    fleet::{CapacitySnapshot, HealthState, ProviderSnapshot},
    ids::{HardwareClass, ModelRevision, SessionId, SessionRevision, TrustRevision},
    request::ProviderFence,
    tokens::{KvBytes, TokenCount},
    traits::ProviderTraits,
};
use darkbloom_coordinator_protocol::{
    v1::{AttestationChallenge, CoordinatorMessage, ProviderMessage, parse_provider_message},
    v2::{CoordinatorControlMessage, ProviderControlMessage, ProviderTerminal, TerminalAck},
};
use futures_util::StreamExt;
use sha2::{Digest as _, Sha256};
use thiserror::Error;
use tokio::{
    sync::{OwnedSemaphorePermit, Semaphore, mpsc, oneshot},
    task::JoinSet,
    time::{MissedTickBehavior, timeout},
};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::{
    catalog::MemoryCatalog,
    crypto::{
        DurableIoPool, ReplayObligation, ReplayProofSigner, ReplayProofStore, ReplayStoreError,
        SessionEpochStore, TerminalDispositionStore, TerminalKey, TerminalResolution,
        X25519PublicKey,
    },
    fleet::{
        FleetCommandError, FleetHandle, FleetHandleError, HeartbeatPublishError, ProviderCapacity,
        ProviderHeartbeat, ProviderLifecycle, WriterHeadroom,
    },
    provider::{
        NegotiatedProtocol, ProviderReadError, ProviderReaderConfig, ProviderRegistry,
        ProviderSession, ProviderSessionConfig, SessionEvent, SessionEventReceiver,
        SessionEventSender, SessionIdentity, receive_registration,
    },
    provider_control::ProviderControlPlane,
    request::InboundAttemptEvent,
    surface::operations::AdmissionGuard,
    telemetry::datadog::{self, Metric, Tag, TagKey},
    trust::{
        BoundedBlockingVerifier, ChallengeExpectation, CredentialRegistry, RegistrationTrust,
        TrustFloor, TrustLevel, verify_challenge, verify_registration,
    },
};

use super::{
    state::{PilotSession, RequestRouteError, RequestTable, SessionDirectory, core_provider_id},
    telemetry::{PilotTelemetry, PilotTelemetryEvent},
};

const CHALLENGE_TIMEOUT: Duration = Duration::from_secs(10);
const REPLAY_RETRY_INTERVAL: Duration = Duration::from_secs(1);
const REPLAY_BATCH_SIZE: usize = 16;
const UNKNOWN_CURRENT_TERMINAL_LIMIT: usize = 8;

pub struct ProviderConnection {
    pub socket: WebSocket,
    admission: Option<AdmissionGuard>,
}

#[derive(Clone)]
pub struct ProviderAcceptor {
    sender: mpsc::Sender<ProviderConnection>,
}

impl ProviderAcceptor {
    pub fn try_accept(&self, socket: WebSocket) -> Result<(), ProviderAcceptError> {
        self.try_accept_with_admission(socket, None)
    }

    pub fn try_accept_guarded(
        &self,
        socket: WebSocket,
        admission: AdmissionGuard,
    ) -> Result<(), ProviderAcceptError> {
        self.try_accept_with_admission(socket, Some(admission))
    }

    fn try_accept_with_admission(
        &self,
        socket: WebSocket,
        admission: Option<AdmissionGuard>,
    ) -> Result<(), ProviderAcceptError> {
        self.sender
            .try_send(ProviderConnection { socket, admission })
            .map_err(|error| match error {
                mpsc::error::TrySendError::Full(_) => ProviderAcceptError::Full,
                mpsc::error::TrySendError::Closed(_) => ProviderAcceptError::Closed,
            })
    }

    #[must_use]
    pub fn remaining_capacity(&self) -> usize {
        self.sender.capacity()
    }
}

pub struct ProviderOwner {
    receiver: mpsc::Receiver<ProviderConnection>,
    services: Arc<ProviderServices>,
    slots: Arc<Semaphore>,
}

pub struct ProviderServices {
    pub credentials: CredentialRegistry,
    pub trust_verifier: Arc<BoundedBlockingVerifier>,
    pub trust_floor: TrustFloor,
    pub established_trust: TrustLevel,
    pub registry: Arc<ProviderRegistry>,
    pub events: SessionEventSender,
    pub session_config: ProviderSessionConfig,
    pub directory: Arc<SessionDirectory>,
    pub requests: Arc<RequestTable>,
    pub fleet: FleetHandle,
    pub catalog: MemoryCatalog,
    pub replay_signer: Arc<ReplayProofSigner>,
    pub replay_store: Arc<ReplayProofStore>,
    pub terminal_store: Arc<TerminalDispositionStore>,
    pub epoch_store: Arc<SessionEpochStore>,
    pub durable_io: DurableIoPool,
    pub activation: ProviderActivationGate,
    pub telemetry: PilotTelemetry,
    pub ledger: Option<crate::ledger::LedgerService>,
    pub durable_terminals: bool,
    pub attempt_queries: Arc<super::reconciliation::AttemptQueryRegistry>,
    pub provider_control: Option<ProviderControlPlane>,
}

enum ActivationAckEntry {
    Waiting(oneshot::Sender<Result<(), Arc<str>>>),
    Completed(Result<(), Arc<str>>),
}

struct ActivationAckState {
    maximum: usize,
    entries: BTreeMap<SessionIdentity, ActivationAckEntry>,
}

#[derive(Clone)]
pub struct ProviderActivationGate {
    slot: Arc<Semaphore>,
    wait_timeout: Duration,
    acknowledgements: Arc<Mutex<ActivationAckState>>,
}

impl ProviderActivationGate {
    pub fn new(wait_timeout: Duration, maximum: usize) -> Self {
        assert!(!wait_timeout.is_zero());
        assert!(maximum > 0);
        Self {
            slot: Arc::new(Semaphore::new(1)),
            wait_timeout,
            acknowledgements: Arc::new(Mutex::new(ActivationAckState {
                maximum,
                entries: BTreeMap::new(),
            })),
        }
    }

    async fn enter(&self) -> Result<OwnedSemaphorePermit, ProviderConnectionError> {
        timeout(self.wait_timeout, self.slot.clone().acquire_owned())
            .await
            .map_err(|_| ProviderConnectionError::ActivationTimeout)?
            .map_err(|_| ProviderConnectionError::ActivationClosed)
    }

    fn register(
        &self,
        identity: SessionIdentity,
        acknowledgement: oneshot::Sender<Result<(), Arc<str>>>,
    ) {
        let immediate = {
            let mut state = self
                .acknowledgements
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            match state.entries.remove(&identity) {
                Some(ActivationAckEntry::Completed(result)) => Some((acknowledgement, result)),
                Some(ActivationAckEntry::Waiting(previous)) => {
                    state
                        .entries
                        .insert(identity, ActivationAckEntry::Waiting(previous));
                    Some((
                        acknowledgement,
                        Err(Arc::from("duplicate registration activation barrier")),
                    ))
                }
                None if state.entries.len() == state.maximum => Some((
                    acknowledgement,
                    Err(Arc::from("registration activation barrier is full")),
                )),
                None => {
                    state
                        .entries
                        .insert(identity, ActivationAckEntry::Waiting(acknowledgement));
                    None
                }
            }
        };
        if let Some((acknowledgement, result)) = immediate {
            let _ = acknowledgement.send(result);
        }
    }

    fn complete(
        &self,
        identity: SessionIdentity,
        result: Result<(), Arc<str>>,
    ) -> Result<(), ProviderConnectionError> {
        let waiting = {
            let mut state = self
                .acknowledgements
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            match state.entries.remove(&identity) {
                Some(ActivationAckEntry::Waiting(acknowledgement)) => Some(acknowledgement),
                Some(ActivationAckEntry::Completed(_)) => {
                    return Err(ProviderConnectionError::ActivationClosed);
                }
                None if state.entries.len() == state.maximum => {
                    return Err(ProviderConnectionError::ActivationClosed);
                }
                None => {
                    state
                        .entries
                        .insert(identity, ActivationAckEntry::Completed(result));
                    return Ok(());
                }
            }
        };
        waiting
            .expect("waiting activation acknowledgement was matched")
            .send(result)
            .map_err(|_| ProviderConnectionError::ActivationClosed)
    }

    fn forget(&self, identity: SessionIdentity) {
        self.acknowledgements
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .entries
            .remove(&identity);
    }
}

impl ProviderOwner {
    pub fn new(capacity: usize, services: Arc<ProviderServices>) -> (Self, ProviderAcceptor) {
        assert!(capacity > 0);
        let (sender, receiver) = mpsc::channel(capacity);
        (
            Self {
                receiver,
                services,
                slots: Arc::new(Semaphore::new(capacity)),
            },
            ProviderAcceptor { sender },
        )
    }

    pub async fn run(mut self, cancellation: CancellationToken) -> Result<(), ProviderOwnerError> {
        let mut sessions = JoinSet::new();
        loop {
            tokio::select! {
                biased;
                () = cancellation.cancelled() => {
                    self.receiver.close();
                    break;
                }
                joined = sessions.join_next(), if !sessions.is_empty() => {
                    if let Some(result) = joined {
                        result.map_err(|error| ProviderOwnerError::TaskJoin(
                            Arc::from(error.to_string())
                        ))?;
                    }
                }
                connection = self.receiver.recv() => {
                    let Some(connection) = connection else {
                        if cancellation.is_cancelled() {
                            break;
                        }
                        return Err(ProviderOwnerError::MailboxClosed);
                    };
                    let permit = match self.slots.clone().try_acquire_owned() {
                        Ok(permit) => permit,
                        Err(_) => continue,
                    };
                    let services = self.services.clone();
                    let shutdown = cancellation.clone();
                    sessions.spawn(async move {
                        if let Err(error) = serve_provider(
                            connection.socket,
                            services.clone(),
                            shutdown,
                            permit,
                            connection.admission,
                        )
                        .await
                        {
                            services.telemetry.emit(PilotTelemetryEvent::ProviderRejected);
                            datadog::counter(
                                Metric::ProviderTrust,
                                1,
                                &[
                                    Tag::new(TagKey::Trust, "unknown"),
                                    Tag::new(TagKey::Outcome, "rejected"),
                                    Tag::new(TagKey::Reason, "session_error"),
                                ],
                            );
                            tracing::warn!(error = %error, "provider session ended");
                        }
                    });
                }
            }
        }
        while let Some(joined) = sessions.join_next().await {
            joined.map_err(|error| ProviderOwnerError::TaskJoin(Arc::from(error.to_string())))?;
        }
        Ok(())
    }
}

pub async fn run_provider_events(
    mut events: SessionEventReceiver,
    services: Arc<ProviderServices>,
    cancellation: CancellationToken,
) -> Result<(), ProviderEventError> {
    let mut retry = tokio::time::interval(REPLAY_RETRY_INTERVAL);
    retry.set_missed_tick_behavior(MissedTickBehavior::Skip);
    let mut durable_tasks = JoinSet::new();
    let mut durable_providers = BTreeSet::new();
    let mut pending_replay_acks: BTreeMap<
        darkbloom_coordinator_protocol::v2::ProviderId,
        VecDeque<(SessionIdentity, Box<ProviderControlMessage>)>,
    > = BTreeMap::new();
    loop {
        tokio::select! {
            biased;
            () = cancellation.cancelled() => break,
            joined = durable_tasks.join_next(), if !durable_tasks.is_empty() => {
                let (provider_id, result) = joined
                    .expect("durable task set was nonempty")
                    .map_err(|error| ProviderEventError::TaskJoin(Arc::from(error.to_string())))?;
                result?;
                if let Some((identity, message)) = pending_replay_acks
                    .get_mut(&provider_id)
                    .and_then(VecDeque::pop_front)
                {
                    let services = services.clone();
                    durable_tasks.spawn(async move {
                        let result =
                            handle_durable_control(identity, *message, &services).await;
                        (identity.provider_id, result)
                    });
                } else {
                    pending_replay_acks.remove(&provider_id);
                    durable_providers.remove(&provider_id);
                }
            }
            event = events.recv() => {
                let Some(event) = event else {
                    return Err(ProviderEventError::MailboxClosed);
                };
                match event {
                    SessionEvent::V2Control { identity, message }
                        if matches!(message.as_ref(), ProviderControlMessage::ReplayFenceAck(_)) =>
                    {
                        if durable_providers.insert(identity.provider_id) {
                            let services = services.clone();
                            durable_tasks.spawn(async move {
                                let result =
                                    handle_durable_control(identity, *message, &services).await;
                                (identity.provider_id, result)
                            });
                        } else {
                            let pending = pending_replay_acks
                                .entry(identity.provider_id)
                                .or_default();
                            if pending.len() < REPLAY_BATCH_SIZE {
                                pending.push_back((identity, message));
                            }
                        }
                    }
                    event => {
                        let identity = session_event_identity(&event);
                        if let Err(error) = handle_event(event, &services).await {
                            if provider_event_error_is_local(&error) {
                                fence_provider(
                                    identity,
                                    "provider event failed locally",
                                    &services.directory,
                                    &services.requests,
                                    &services.fleet,
                                )
                                .await;
                                tracing::warn!(
                                    provider_id = %identity.provider_id,
                                    session_epoch = identity.session_epoch.0,
                                    error = %error,
                                    "pilot provider event quarantined"
                                );
                            } else {
                                return Err(error);
                            }
                        }
                    }
                }
            }
            _ = retry.tick() => {
                for session in services.directory.sessions() {
                    if !durable_providers.insert(session.identity.provider_id) {
                        continue;
                    }
                    let services = services.clone();
                    durable_tasks.spawn(async move {
                        let provider_id = session.identity.provider_id;
                        let result = retry_session_replay(session, &services).await;
                        (provider_id, result)
                    });
                }
            }
        }
    }
    while let Some(joined) = durable_tasks.join_next().await {
        let (_, result) =
            joined.map_err(|error| ProviderEventError::TaskJoin(Arc::from(error.to_string())))?;
        result?;
    }
    Ok(())
}

fn session_event_identity(event: &SessionEvent) -> SessionIdentity {
    match event {
        SessionEvent::Registered { identity, .. }
        | SessionEvent::V1 { identity, .. }
        | SessionEvent::V2Control { identity, .. }
        | SessionEvent::V2Binary { identity, .. } => *identity,
    }
}

fn provider_event_error_is_local(error: &ProviderEventError) -> bool {
    matches!(
        error,
        ProviderEventError::Writer(_) | ProviderEventError::DurableIo(_)
    ) || matches!(
        error,
        ProviderEventError::Replay(replay) if replay_error_is_provider_local(replay)
    )
}

async fn handle_durable_control(
    identity: SessionIdentity,
    message: ProviderControlMessage,
    services: &ProviderServices,
) -> Result<(), ProviderEventError> {
    match handle_control(identity, message, services).await {
        Err(ProviderEventError::Replay(error)) if replay_error_is_provider_local(&error) => {
            fence_provider(
                identity,
                "provider durable replay operation failed locally",
                &services.directory,
                &services.requests,
                &services.fleet,
            )
            .await;
            Ok(())
        }
        result => result,
    }
}

async fn serve_provider(
    mut socket: WebSocket,
    services: Arc<ProviderServices>,
    shutdown: CancellationToken,
    _permit: OwnedSemaphorePermit,
    admission: Option<AdmissionGuard>,
) -> Result<(), ProviderConnectionError> {
    let registration = receive_registration(
        &mut socket,
        services.session_config.reader,
        services.session_config.registration_timeout,
    )
    .await?;
    let auth_token = registration.registration().auth_token.clone();
    let provider_key = X25519PublicKey::from_base64(&registration.registration().public_key)?;
    let durable_identity = match &services.provider_control {
        Some(control) => Some(control.authenticate(&auth_token).await?),
        None => None,
    };
    let pending_finalizer = if durable_identity.is_none() {
        Some(services.credentials.prepare(&auth_token)?)
    } else {
        None
    };
    let pending_provider_id = pending_finalizer.as_ref().map_or_else(
        || {
            durable_identity
                .as_ref()
                .expect("durable identity")
                .provider_id
        },
        |pending| pending.provider_id(),
    );
    let mut pending = if let Some(finalizer) = &pending_finalizer {
        let begin_lease = finalizer.lease();
        let credentials = services.credentials.clone();
        match services
            .durable_io
            .run("begin provider credential verification", move || {
                credentials.begin_prepared(begin_lease)
            })
            .await
        {
            Ok(Ok(pending)) => Some(pending),
            Ok(Err(error)) => {
                finalizer.abandon();
                release_pending_credential(&services, finalizer.lease(), pending_provider_id).await;
                return Err(error.into());
            }
            Err(error) => {
                finalizer.abandon();
                release_pending_credential(&services, finalizer.lease(), pending_provider_id).await;
                return Err(error.into());
            }
        }
    } else {
        None
    };
    let credential_result = {
        let credential_verification = async {
            let provider_id = pending_provider_id;
            let signed_attestation = registration
                .signed_attestation()
                .ok_or(ProviderConnectionError::MissingAttestation)?
                .to_vec();
            let verified = services
                .trust_verifier
                .run(provider_id, move || {
                    verify_registration(&signed_attestation, provider_key)
                })
                .await?
                .value?;
            let expectation = send_challenge(&mut socket).await?;
            let response = receive_challenge_response(
                &mut socket,
                services.session_config.reader,
                CHALLENGE_TIMEOUT,
            )
            .await?;
            let challenge_registration = verified.clone();
            let challenge_expectation = expectation.clone();
            let challenge_response = response.clone();
            let established = if durable_identity.is_some() {
                TrustLevel::SelfSigned
            } else {
                services.established_trust
            };
            let floor = if durable_identity.is_some() {
                TrustFloor::SELF_ROUTE
            } else {
                services.trust_floor
            };
            services
                .trust_verifier
                .run(provider_id, move || {
                    verify_challenge(
                        &challenge_registration,
                        &challenge_expectation,
                        &challenge_response,
                        established,
                        floor,
                    )
                })
                .await?
                .value?;
            if let Some(pending) = pending.take() {
                let signing_key = verified.se_public_key.clone();
                services
                    .durable_io
                    .run("bind provider identity", move || {
                        pending.complete(provider_key, signing_key)
                    })
                    .await??;
            }
            Ok::<_, ProviderConnectionError>((provider_id, verified, response))
        };
        tokio::pin!(credential_verification);
        tokio::select! {
            biased;
            () = shutdown.cancelled() => Err(ProviderConnectionError::Shutdown),
            result = &mut credential_verification => result,
        }
    };
    if credential_result.is_err()
        && let Some(finalizer) = &pending_finalizer
    {
        finalizer.abandon();
        release_pending_credential(&services, finalizer.lease(), pending_provider_id).await;
    }
    let (provider_id, mut verified, challenge_response) = credential_result?;

    let epoch_store = services.epoch_store.clone();
    let epoch = services
        .durable_io
        .run("allocate provider epoch", move || {
            epoch_store.allocate(provider_id)
        })
        .await??;
    if let (Some(control), Some(identity)) = (&services.provider_control, &durable_identity) {
        control
            .bind_identity(identity, provider_key, &verified.se_public_key)
            .await?;
        control
            .establish_hardware_trust(identity, epoch, &verified, &challenge_response)
            .await?;
        verified.level = TrustLevel::Hardware;
    }
    let activation_permit = services.activation.enter().await?;
    if let Some(ledger) = &services.ledger {
        ledger
            .ensure_provider_trusted(
                Uuid::from_bytes(*provider_id.as_bytes()),
                crate::ledger::Version::new(epoch.0)
                    .map_err(crate::ledger::LedgerError::Invalid)?,
            )
            .await?;
    }
    let reservation =
        services
            .registry
            .reserve_with_epoch(provider_id, registration.registration(), epoch)?;
    if matches!(reservation.protocol(), NegotiatedProtocol::V2(_)) {
        let replay_store = services.replay_store.clone();
        let identity = reservation.identity();
        services
            .durable_io
            .run("reserve provider replay obligation", move || {
                replay_store.reserve_obligation(ReplayObligation {
                    provider_id: identity.provider_id,
                    provider_process_generation: identity.provider_process_generation,
                    session_epoch: identity.session_epoch,
                })
            })
            .await
            .map_err(ReplayStoreError::IoPool)??;
    }
    let session = ProviderSession::activate_verified(
        socket,
        registration,
        reservation,
        services.registry.clone(),
        services.events.clone(),
        services.session_config,
    )
    .await?;
    let cancellation = session.cancellation_token();
    let identity = session.identity();
    let ended_v2 = matches!(session.protocol(), NegotiatedProtocol::V2(_));
    let replaced = session.replaced_identity();
    let replaced_protocol = session.replaced_protocol().cloned();
    if session.identity().session_epoch.0 == 0
        || services.registry.current(provider_id) != Some(identity)
    {
        let _ = services.activation.complete(
            identity,
            Err(Arc::from("provider activation was superseded")),
        );
        return Err(ProviderConnectionError::StaleActivation);
    }
    if let (Some(control), Some(durable_identity)) =
        (&services.provider_control, durable_identity.as_ref())
    {
        control
            .persist_connected(
                durable_identity,
                session.registration().registration(),
                Uuid::from_bytes(*identity.provider_process_generation.as_bytes()),
                identity.session_epoch,
                &verified,
            )
            .await?;
    }
    let negotiated = session.protocol().clone();
    let raw_provider_version = session.registration().registration().version.as_str();
    let provider_version = provider_version_class(raw_provider_version);
    let trust_level = match verified.level {
        TrustLevel::Untrusted => "untrusted",
        TrustLevel::SelfSigned => "self_signed",
        TrustLevel::Hardware => "hardware",
    };
    let pilot_session = match build_pilot_session(
        &session,
        negotiated,
        provider_key,
        verified,
        &services.catalog,
    ) {
        Ok(session) => session,
        Err(error) => {
            let _ = services
                .activation
                .complete(identity, Err(Arc::from(error.to_string())));
            return Err(error);
        }
    };
    if let Err(error) = install_current(pilot_session, replaced, replaced_protocol, &services).await
    {
        let _ = services
            .activation
            .complete(identity, Err(Arc::from(error.to_string())));
        cleanup_current(identity, &services).await;
        if let Some(replaced) = replaced {
            cleanup_current(replaced, &services).await;
        }
        return Err(error);
    }
    if let Err(error) = services.activation.complete(identity, Ok(())) {
        cleanup_current(identity, &services).await;
        return Err(error);
    }
    drop(activation_permit);
    drop(admission);
    services
        .telemetry
        .emit(PilotTelemetryEvent::ProviderConnected);
    datadog::gauge(
        Metric::ProviderSessions,
        services.directory.visible_count() as f64,
        &[],
    );
    datadog::counter(
        Metric::ProviderVersion,
        1,
        &[
            Tag::new(TagKey::ProviderVersion, provider_version),
            Tag::new(TagKey::Outcome, provider_version),
        ],
    );
    datadog::counter(
        Metric::ProviderTrust,
        1,
        &[
            Tag::new(TagKey::Trust, trust_level),
            Tag::new(TagKey::Outcome, "established"),
        ],
    );

    let wait = session.wait();
    tokio::pin!(wait);
    let result = tokio::select! {
        biased;
        () = shutdown.cancelled() => {
            cancellation.cancel();
            wait.await
        }
        result = &mut wait => result,
    };
    let replay_result = if ended_v2 {
        Some(persist_replay_fence(identity, &services).await)
    } else {
        None
    };
    services.activation.forget(identity);
    cleanup_current(identity, &services).await;
    datadog::gauge(
        Metric::ProviderSessions,
        services.directory.visible_count() as f64,
        &[],
    );
    if let Some(replay_result) = replay_result {
        replay_result?;
    }
    result?;
    Ok(())
}

fn provider_version_class(value: &str) -> &'static str {
    let minimum = std::env::var("EIGENINFERENCE_MIN_PROVIDER_VERSION").unwrap_or_default();
    let current = std::env::var("EIGENINFERENCE_PROVIDER_VERSION").unwrap_or_default();
    classify_provider_version(value, &minimum, &current)
}

fn classify_provider_version(value: &str, minimum: &str, current: &str) -> &'static str {
    if minimum.is_empty() {
        return "unconfigured";
    }
    let (Some(version), Some(floor)) = (numeric_version(value), numeric_version(minimum)) else {
        return "invalid";
    };
    if version < floor {
        return "below_floor";
    }
    if current.is_empty() {
        return "at_or_above_floor";
    }
    let Some(current) = numeric_version(current).filter(|current| *current >= floor) else {
        return "invalid";
    };
    match version.cmp(&current) {
        std::cmp::Ordering::Less => "older_supported",
        std::cmp::Ordering::Equal => "current",
        std::cmp::Ordering::Greater => "newer",
    }
}

fn numeric_version(value: &str) -> Option<[u16; 3]> {
    let core = value
        .strip_prefix('v')
        .unwrap_or(value)
        .split(['-', '+'])
        .next()?;
    let mut components = core.split('.');
    let parsed = [
        components.next()?.parse().ok()?,
        components.next()?.parse().ok()?,
        components.next()?.parse().ok()?,
    ];
    if components.next().is_some() {
        return None;
    }
    Some(parsed)
}

async fn release_pending_credential(
    services: &ProviderServices,
    lease: crate::trust::PendingCredentialLease,
    provider_id: darkbloom_coordinator_protocol::v2::ProviderId,
) {
    let credentials = services.credentials.clone();
    if let Err(error) = services
        .durable_io
        .run("release failed provider credential", move || {
            credentials.release_pending(&lease)
        })
        .await
    {
        tracing::warn!(
            provider_id = %provider_id,
            error = %error,
            "failed credential cleanup left an expiring abandoned lease"
        );
    }
}

async fn send_challenge(
    socket: &mut WebSocket,
) -> Result<ChallengeExpectation, ProviderConnectionError> {
    let nonce = Arc::<str>::from(Uuid::new_v4().to_string());
    let timestamp = Arc::<str>::from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| ProviderConnectionError::Clock)?
            .as_millis()
            .to_string(),
    );
    let message = CoordinatorMessage::AttestationChallenge(AttestationChallenge {
        nonce: nonce.to_string(),
        timestamp: timestamp.to_string(),
    });
    let wire = serde_json::to_string(&message)
        .map_err(|error| ProviderConnectionError::Challenge(Arc::from(error.to_string())))?;
    timeout(CHALLENGE_TIMEOUT, socket.send(Message::Text(wire.into())))
        .await
        .map_err(|_| ProviderConnectionError::ChallengeTimeout)?
        .map_err(|error| ProviderConnectionError::Challenge(Arc::from(error.to_string())))?;
    Ok(ChallengeExpectation { nonce, timestamp })
}

async fn receive_challenge_response(
    socket: &mut WebSocket,
    reader: ProviderReaderConfig,
    deadline: Duration,
) -> Result<darkbloom_coordinator_protocol::v1::AttestationResponse, ProviderConnectionError> {
    let receive = async {
        loop {
            match socket.next().await {
                Some(Ok(Message::Text(wire))) => {
                    if wire.len() > reader.maximum_json_bytes {
                        return Err(ProviderConnectionError::Challenge(Arc::from(
                            "attestation response exceeds JSON bound",
                        )));
                    }
                    let parsed = parse_provider_message(wire.as_bytes()).map_err(|error| {
                        ProviderConnectionError::Challenge(Arc::from(error.to_string()))
                    })?;
                    return match parsed.message {
                        ProviderMessage::AttestationResponse(response) => Ok(response),
                        other => Err(ProviderConnectionError::Challenge(Arc::from(format!(
                            "expected attestation_response, got {}",
                            other.message_type()
                        )))),
                    };
                }
                Some(Ok(Message::Ping(value))) => {
                    socket.send(Message::Pong(value)).await.map_err(|error| {
                        ProviderConnectionError::Challenge(Arc::from(error.to_string()))
                    })?;
                }
                Some(Ok(Message::Pong(_))) => {}
                Some(Ok(Message::Binary(_) | Message::Close(_))) | None => {
                    return Err(ProviderConnectionError::Challenge(Arc::from(
                        "provider closed during attestation challenge",
                    )));
                }
                Some(Err(error)) => {
                    return Err(ProviderConnectionError::Challenge(Arc::from(
                        error.to_string(),
                    )));
                }
            }
        }
    };
    timeout(deadline, receive)
        .await
        .map_err(|_| ProviderConnectionError::ChallengeTimeout)?
}

fn build_pilot_session(
    session: &ProviderSession,
    protocol: NegotiatedProtocol,
    provider_key: X25519PublicKey,
    trust: RegistrationTrust,
    catalog: &MemoryCatalog,
) -> Result<PilotSession, ProviderConnectionError> {
    let identity = session.identity();
    let trust_level = trust.level;
    let registration = session.registration().registration();
    let model = catalog.models().next().expect("one-model catalog");
    let advertised = registration.models.iter().find(|candidate| {
        catalog
            .resolve(&candidate.id)
            .is_some_and(|resolved| resolved.id == model.id)
    });
    let model_eligible = advertised.is_some_and(|candidate| {
        candidate.template_render_ok.unwrap_or(true) && !candidate.is_vision
    });
    let revision = identity.session_epoch.0;
    let fence = ProviderFence {
        provider_id: core_provider_id(identity.provider_id),
        session_id: session_id(identity),
        session_revision: SessionRevision::new(revision)
            .map_err(|error| ProviderConnectionError::Lifecycle(Arc::from(error.to_string())))?,
        trust_revision: TrustRevision::new(revision)
            .map_err(|error| ProviderConnectionError::Lifecycle(Arc::from(error.to_string())))?,
        model_id: model.id.clone(),
        model_revision: ModelRevision::new(revision)
            .map_err(|error| ProviderConnectionError::Lifecycle(Arc::from(error.to_string())))?,
    };
    Ok(PilotSession {
        identity,
        protocol,
        writer: session.writer(),
        provider_key,
        signing_key: trust.se_public_key,
        trust_level,
        fence,
        control_only: true,
        model_eligible,
    })
}

async fn install_current(
    mut session: PilotSession,
    replaced: Option<SessionIdentity>,
    replaced_protocol: Option<NegotiatedProtocol>,
    services: &ProviderServices,
) -> Result<(), ProviderConnectionError> {
    let mut replay_blocked = false;
    if let Some(replaced) = replaced {
        services.requests.cancel_session(replaced);
        remove_fleet(replaced, &services.fleet).await;
        ensure_current(session.identity, services)?;
        if matches!(replaced_protocol, Some(NegotiatedProtocol::V2(_))) {
            match persist_replay_fence(replaced, services).await {
                Ok(_) => {}
                Err(error) if replay_error_is_provider_local(&error) => {
                    replay_blocked = true;
                    tracing::warn!(
                        provider_id = %replaced.provider_id,
                        error = %error,
                        "provider replay partition full; session remains control-only"
                    );
                }
                Err(error) => return Err(error.into()),
            }
            ensure_current(session.identity, services)?;
        }
    }
    match repair_replay_obligations(session.identity, services).await {
        Ok(()) => {}
        Err(error) if replay_error_is_provider_local(&error) => {
            replay_blocked = true;
            tracing::warn!(
                provider_id = %session.identity.provider_id,
                error = %error,
                "provider replay obligation repair failed; session remains control-only"
            );
        }
        Err(error) => return Err(error.into()),
    }
    ensure_current(session.identity, services)?;
    let (pending_proofs, historical_obligations) =
        replay_status(session.identity, services).await?;
    let has_replay = pending_proofs != 0 || historical_obligations != 0;
    session.control_only =
        !session.is_v2() || !session.model_eligible || has_replay || replay_blocked;
    services.directory.install(session.clone());
    if session.is_v2() && !session.control_only {
        apply_lifecycle(&session, &services.fleet).await?;
        ensure_current(session.identity, services)?;
    }
    send_replay_batch(&session, services).await?;
    ensure_current(session.identity, services)?;
    Ok(())
}

async fn repair_replay_obligations(
    current: SessionIdentity,
    services: &ProviderServices,
) -> Result<(), ReplayStoreError> {
    let replay_store = services.replay_store.clone();
    let obligations = services
        .durable_io
        .run("load provider replay obligations", move || {
            replay_store.obligations_for_provider(current.provider_id)
        })
        .await
        .map_err(ReplayStoreError::IoPool)?;
    for obligation in obligations {
        if obligation.provider_process_generation == current.provider_process_generation
            && obligation.session_epoch == current.session_epoch
        {
            continue;
        }
        persist_replay_fence(
            SessionIdentity {
                provider_id: obligation.provider_id,
                provider_process_generation: obligation.provider_process_generation,
                session_epoch: obligation.session_epoch,
            },
            services,
        )
        .await?;
    }
    Ok(())
}

async fn replay_status(
    current: SessionIdentity,
    services: &ProviderServices,
) -> Result<(usize, usize), ReplayStoreError> {
    let replay_store = services.replay_store.clone();
    services
        .durable_io
        .run("read provider replay status", move || {
            let pending = replay_store.pending_for_provider(current.provider_id);
            let historical = replay_store
                .obligations_for_provider(current.provider_id)
                .into_iter()
                .filter(|obligation| {
                    obligation.provider_process_generation != current.provider_process_generation
                        || obligation.session_epoch != current.session_epoch
                })
                .count();
            (pending, historical)
        })
        .await
        .map_err(ReplayStoreError::IoPool)
}

fn ensure_current(
    identity: SessionIdentity,
    services: &ProviderServices,
) -> Result<(), ProviderConnectionError> {
    if services.registry.current(identity.provider_id) == Some(identity) {
        Ok(())
    } else {
        Err(ProviderConnectionError::StaleActivation)
    }
}

async fn persist_replay_fence(
    identity: SessionIdentity,
    services: &ProviderServices,
) -> Result<(), ReplayStoreError> {
    let proof = services.replay_signer.sign(
        identity.provider_id,
        identity.provider_process_generation,
        identity.session_epoch,
        services.fleet.snapshot().revision().get(),
    );
    let replay_store = services.replay_store.clone();
    services
        .durable_io
        .run("fulfill replay fence obligation", move || {
            replay_store.fulfill_obligation(proof)
        })
        .await
        .map_err(ReplayStoreError::IoPool)?
        .map(|_| ())
}

async fn cleanup_current(identity: SessionIdentity, services: &ProviderServices) {
    if services.directory.remove_if_current(identity).is_some() {
        services.requests.cancel_session(identity);
        remove_fleet(identity, &services.fleet).await;
    }
    if let Some(control) = &services.provider_control
        && let Err(error) = control
            .persist_disconnected(
                identity.provider_id,
                identity.session_epoch,
                "session ended",
            )
            .await
    {
        tracing::warn!(
            provider_id = %identity.provider_id,
            session_epoch = identity.session_epoch.0,
            error = %error,
            "failed to persist provider disconnect"
        );
    }
}

async fn handle_event(
    event: SessionEvent,
    services: &ProviderServices,
) -> Result<(), ProviderEventError> {
    match event {
        SessionEvent::Registered {
            identity,
            activation,
            ..
        } => {
            services.activation.register(identity, activation);
            Ok(())
        }
        SessionEvent::V1 { identity, message } => {
            if matches!(*message, ProviderMessage::Heartbeat(_))
                && let Some(control) = &services.provider_control
            {
                match control
                    .persist_heartbeat(identity.provider_id, identity.session_epoch)
                    .await
                {
                    Ok(true) => {}
                    Ok(false) => {
                        fence_provider(
                            identity,
                            "provider credential was revoked or session was superseded",
                            &services.directory,
                            &services.requests,
                            &services.fleet,
                        )
                        .await;
                        return Ok(());
                    }
                    Err(crate::provider_control::ProviderControlError::Draining) => {
                        fence_provider(
                            identity,
                            "coordinator is draining",
                            &services.directory,
                            &services.requests,
                            &services.fleet,
                        )
                        .await;
                        return Ok(());
                    }
                    Err(error) => return Err(error.into()),
                }
            }
            if matches!(*message, ProviderMessage::Heartbeat(_))
                && let Some(session) = services.directory.current(identity.provider_id)
                && session.identity == identity
                && session.is_v2()
                && !session.control_only
                && let Some(sequence) = services.directory.next_heartbeat_sequence(identity)
            {
                let headroom = session.writer.headroom();
                let writer = WriterHeadroom::new(
                    headroom.revision,
                    headroom.available_items,
                    headroom.available_bytes,
                )
                .expect("provider writer revisions begin at one");
                services.fleet.publish_heartbeat(ProviderHeartbeat::new(
                    sequence,
                    session.fence.clone(),
                    provider_capacity(),
                    HealthState::new(),
                    writer,
                ))?;
            }
            Ok(())
        }
        SessionEvent::V2Binary { identity, frame } => {
            if services.registry.is_current(identity) {
                let attempt = frame.header.attempt_identity();
                if !identity.matches_attempt(&attempt) {
                    fence_provider(
                        identity,
                        "provider binary frame carried a foreign session identity",
                        &services.directory,
                        &services.requests,
                        &services.fleet,
                    )
                    .await;
                    return Ok(());
                }
                match services
                    .requests
                    .open_binary(&frame.header, &frame.ciphertext)
                {
                    Ok(plaintext) => {
                        if let Err(error) = services.requests.route(
                            &attempt,
                            InboundAttemptEvent::Chunk {
                                header: frame.header,
                                plaintext,
                            },
                        ) {
                            handle_route_error(identity, error, services).await;
                        }
                    }
                    Err(RequestRouteError::Unknown | RequestRouteError::Stale) => {}
                    Err(error) => {
                        fence_provider(
                            identity,
                            "provider binary response authentication failed",
                            &services.directory,
                            &services.requests,
                            &services.fleet,
                        )
                        .await;
                        tracing::warn!(
                            provider_id = %identity.provider_id,
                            error = %error,
                            "pilot provider binary frame rejected"
                        );
                    }
                }
            }
            Ok(())
        }
        SessionEvent::V2Control { identity, message } => {
            handle_control(identity, *message, services).await
        }
    }
}

async fn handle_control(
    transport: SessionIdentity,
    message: ProviderControlMessage,
    services: &ProviderServices,
) -> Result<(), ProviderEventError> {
    match message {
        ProviderControlMessage::Prepared(message) => {
            let identity = message.identity.clone();
            if !require_transport_attempt(transport, &identity, services).await {
                return Ok(());
            }
            if let Err(error) = services
                .requests
                .route(&identity, InboundAttemptEvent::Prepared(message))
            {
                handle_route_error(transport, error, services).await;
            }
        }
        ProviderControlMessage::StartAck(message) => {
            let identity = message.identity.clone();
            if !require_transport_recovered_attempt(transport, &identity, services).await {
                return Ok(());
            }
            match services
                .requests
                .route(&identity, InboundAttemptEvent::StartAck(message))
            {
                Ok(()) => {}
                Err(RequestRouteError::Unknown | RequestRouteError::Stale)
                    if services.durable_terminals =>
                {
                    let Some(ledger) = &services.ledger else {
                        return Err(ProviderEventError::DurableTerminalUnavailable);
                    };
                    match ledger
                        .record_recovered_start_ack(
                            crate::ledger::AttemptId::new(Uuid::from_bytes(
                                *identity.attempt_id.as_bytes(),
                            ))
                            .map_err(crate::ledger::LedgerError::Invalid)?,
                            Uuid::from_bytes(*identity.provider_id.as_bytes()),
                            Uuid::from_bytes(*identity.provider_process_generation.as_bytes()),
                            crate::ledger::Version::new(identity.session_epoch.0)
                                .map_err(crate::ledger::LedgerError::Invalid)?,
                        )
                        .await
                    {
                        Ok(()) | Err(crate::ledger::LedgerError::NotFound) => {}
                        Err(error) => return Err(error.into()),
                    }
                }
                Err(error) => handle_route_error(transport, error, services).await,
            }
        }
        ProviderControlMessage::AttemptStatus(status) => {
            if status.identity.provider_id != transport.provider_id
                || status.identity.session_epoch > transport.session_epoch
            {
                fence_provider(
                    transport,
                    "attempt status carried an invalid historical identity",
                    &services.directory,
                    &services.requests,
                    &services.fleet,
                )
                .await;
            } else if let Err(error) = services.attempt_queries.resolve(status) {
                fence_provider(
                    transport,
                    "attempt status conflicted with its pending query",
                    &services.directory,
                    &services.requests,
                    &services.fleet,
                )
                .await;
                tracing::warn!(error = %error, "attempt reconciliation response rejected");
            }
        }
        ProviderControlMessage::StructuredError(message) => {
            let identity = message.identity.clone();
            if !require_transport_attempt(transport, &identity, services).await {
                return Ok(());
            }
            if let Err(error) = services
                .requests
                .route(&identity, InboundAttemptEvent::StructuredError(message))
            {
                handle_route_error(transport, error, services).await;
            }
        }
        ProviderControlMessage::Terminal(terminal) => {
            if terminal.identity.provider_id != transport.provider_id {
                fence_provider(
                    transport,
                    "provider terminal carried a foreign provider identity",
                    &services.directory,
                    &services.requests,
                    &services.fleet,
                )
                .await;
            } else if transport.matches_attempt(&terminal.identity) {
                match services.requests.route(
                    &terminal.identity,
                    InboundAttemptEvent::Terminal(terminal.clone()),
                ) {
                    Ok(()) => {}
                    Err(RequestRouteError::Unknown) => {
                        handle_unrouted_terminal(transport, &terminal, services).await?;
                    }
                    Err(RequestRouteError::Stale | RequestRouteError::Closed(_))
                        if services.durable_terminals =>
                    {
                        handle_unrouted_terminal(transport, &terminal, services).await?;
                    }
                    Err(RequestRouteError::Stale) => {}
                    Err(error) => handle_route_error(transport, error, services).await,
                }
            } else {
                handle_unrouted_terminal(transport, &terminal, services).await?;
            }
        }
        ProviderControlMessage::ReplayFenceAck(ack) => {
            if ack.provider_id != transport.provider_id {
                fence_provider(
                    transport,
                    "replay proof ACK carried a foreign provider identity",
                    &services.directory,
                    &services.requests,
                    &services.fleet,
                )
                .await;
                return Ok(());
            }
            let replay_store = services.replay_store.clone();
            let provider_id = ack.provider_id;
            let generation = ack.provider_process_generation;
            let proof_id = ack.proof_id;
            let (acknowledged, pending, historical_obligations) = services
                .durable_io
                .run("acknowledge replay fence", move || {
                    let acknowledged =
                        replay_store.acknowledge(provider_id, generation, proof_id)?;
                    let pending = replay_store.pending_for_provider(provider_id);
                    let historical_obligations = replay_store
                        .obligations_for_provider(provider_id)
                        .into_iter()
                        .filter(|obligation| {
                            obligation.provider_process_generation
                                != transport.provider_process_generation
                                || obligation.session_epoch != transport.session_epoch
                        })
                        .count();
                    Ok::<_, ReplayStoreError>((acknowledged, pending, historical_obligations))
                })
                .await
                .map_err(ReplayStoreError::IoPool)??;
            if acknowledged
                && pending == 0
                && historical_obligations == 0
                && let Some(session) = services.directory.current(ack.provider_id)
                && session.identity == transport
                && session.model_eligible
            {
                apply_lifecycle(&session, &services.fleet).await?;
                services.directory.promote_if_current(transport);
            }
        }
        ProviderControlMessage::ModelGone(message) => {
            if provider_session_matches(transport, &message.identity) {
                remove_fleet(transport, &services.fleet).await;
            } else {
                fence_provider(
                    transport,
                    "model_gone carried a foreign session identity",
                    &services.directory,
                    &services.requests,
                    &services.fleet,
                )
                .await;
            }
        }
        ProviderControlMessage::ModelReady(message) => {
            if !provider_session_matches(transport, &message.identity) {
                fence_provider(
                    transport,
                    "model_ready carried a foreign session identity",
                    &services.directory,
                    &services.requests,
                    &services.fleet,
                )
                .await;
                return Ok(());
            }
            if let Some(session) = services.directory.current(transport.provider_id)
                && session.identity == transport
                && !session.control_only
                && session.model_eligible
                && session.fence.model_id.as_str() == message.model
            {
                apply_lifecycle(&session, &services.fleet).await?;
            }
        }
        ProviderControlMessage::AbortAck(_) | ProviderControlMessage::CancelAck(_) => {}
    }
    Ok(())
}

async fn handle_unrouted_terminal(
    transport: SessionIdentity,
    terminal: &ProviderTerminal,
    services: &ProviderServices,
) -> Result<(), ProviderEventError> {
    let Some(session) = services.directory.current(transport.provider_id) else {
        return Ok(());
    };
    if terminal.identity.provider_id != transport.provider_id {
        fence_provider(
            transport,
            "historical terminal carried a foreign provider identity",
            &services.directory,
            &services.requests,
            &services.fleet,
        )
        .await;
        return Ok(());
    }
    let is_historical = terminal.identity.provider_process_generation
        != transport.provider_process_generation
        || terminal.identity.session_epoch < transport.session_epoch;
    let terminal_provider = terminal.identity.provider_id;
    let signing_key = if let Some(control) = &services.provider_control {
        control.bound_signing_key(terminal_provider).await?
    } else {
        let credentials = services.credentials.clone();
        services
            .durable_io
            .run("load provider signing identity", move || {
                credentials.bound_signing_key(terminal_provider)
            })
            .await?
    };
    let Some(signing_key) = signing_key else {
        fence_provider(
            transport,
            "stable provider signing identity is not durably bound",
            &services.directory,
            &services.requests,
            &services.fleet,
        )
        .await;
        return Ok(());
    };
    if let Err(error) =
        terminal.validate_with(&terminal.identity, |provider, _, digest, signature| {
            provider == terminal.identity.provider_id
                && crate::trust::verify_signature(
                    &signing_key,
                    &base64::engine::general_purpose::STANDARD.encode(signature),
                    digest.as_bytes(),
                )
                .is_ok()
        })
    {
        fence_provider(
            transport,
            "unrouted provider terminal failed signature validation",
            &services.directory,
            &services.requests,
            &services.fleet,
        )
        .await;
        tracing::warn!(
            provider_id = %transport.provider_id,
            error = %error,
            "pilot unrouted terminal rejected"
        );
        return Ok(());
    }
    if services.durable_terminals {
        let Some(ledger) = &services.ledger else {
            return Err(ProviderEventError::DurableTerminalUnavailable);
        };
        let lookup = ledger
            .lookup_terminal(
                crate::ledger::DurableAttemptIdentity {
                    request_id: Uuid::from_bytes(*terminal.identity.request_id.as_bytes()),
                    reservation_id: crate::ledger::ReservationId::new(Uuid::from_bytes(
                        *terminal.identity.reservation_id.as_bytes(),
                    ))
                    .map_err(crate::ledger::LedgerError::Invalid)?,
                    attempt_id: crate::ledger::AttemptId::new(Uuid::from_bytes(
                        *terminal.identity.attempt_id.as_bytes(),
                    ))
                    .map_err(crate::ledger::LedgerError::Invalid)?,
                    provider_id: Uuid::from_bytes(*terminal.identity.provider_id.as_bytes()),
                    provider_process_generation_id: Uuid::from_bytes(
                        *terminal.identity.provider_process_generation.as_bytes(),
                    ),
                    session_epoch: crate::ledger::Version::new(terminal.identity.session_epoch.0)
                        .map_err(crate::ledger::LedgerError::Invalid)?,
                    lease_id: Uuid::from_bytes(*terminal.identity.lease_id.as_bytes()),
                },
                darkbloom_coordinator_core::ids::Digest::new(*terminal.terminal_digest.as_bytes()),
            )
            .await?;
        let disposition = match lookup {
            crate::ledger::TerminalLookup::Known(disposition) => {
                durable_terminal_disposition(disposition)
            }
            crate::ledger::TerminalLookup::Conflict { job_id } => {
                let facts = recovery_terminal_facts(terminal)?;
                ledger
                    .record_terminal_conflict(
                        job_id,
                        facts.attempt_id,
                        &facts,
                        "terminal_digest_conflict",
                        0,
                    )
                    .await?;
                fence_provider(
                    transport,
                    "historical terminal conflicted with durable evidence",
                    &services.directory,
                    &services.requests,
                    &services.fleet,
                )
                .await;
                None
            }
            crate::ledger::TerminalLookup::Absent => {
                if !terminal_epoch_is_trusted(ledger, terminal, transport, services).await? {
                    return Ok(());
                }
                let facts = recovery_terminal_facts(terminal)?;
                match ledger.record_terminal_for_recovery(&facts).await {
                    Ok(crate::ledger::RecoveryTerminalRecordResult::Known(disposition)) => {
                        durable_terminal_disposition(disposition)
                    }
                    Ok(crate::ledger::RecoveryTerminalRecordResult::Pending { .. }) => None,
                    Ok(crate::ledger::RecoveryTerminalRecordResult::Conflict { .. }) => {
                        fence_provider(
                            transport,
                            "historical terminal conflicted with durable evidence",
                            &services.directory,
                            &services.requests,
                            &services.fleet,
                        )
                        .await;
                        None
                    }
                    Err(crate::ledger::LedgerError::NotFound) => {
                        if !is_historical
                            && services
                                .directory
                                .record_unknown_terminal(transport, UNKNOWN_CURRENT_TERMINAL_LIMIT)
                        {
                            fence_provider(
                                transport,
                                "unknown current terminal flood",
                                &services.directory,
                                &services.requests,
                                &services.fleet,
                            )
                            .await;
                        }
                        None
                    }
                    Err(error) => return Err(error.into()),
                }
            }
        };
        if let Some(disposition) = disposition {
            session
                .writer
                .try_send_control_json(&CoordinatorControlMessage::TerminalAck(TerminalAck {
                    identity: terminal.identity.clone(),
                    terminal_digest: terminal.terminal_digest,
                    disposition,
                }))?;
        }
        return Ok(());
    }
    let terminal_store = services.terminal_store.clone();
    let terminal_key = TerminalKey::from(&terminal.identity);
    let terminal_digest = terminal.terminal_digest;
    let resolution = services
        .durable_io
        .run("resolve historical provider terminal", move || {
            terminal_store.resolve_historical(terminal_key, terminal_digest)
        })
        .await?;
    if matches!(resolution, TerminalResolution::Conflict { .. }) {
        return Ok(());
    }
    if matches!(resolution, TerminalResolution::Late) && !is_historical {
        if services
            .directory
            .record_unknown_terminal(transport, UNKNOWN_CURRENT_TERMINAL_LIMIT)
        {
            fence_provider(
                transport,
                "unknown current terminal flood",
                &services.directory,
                &services.requests,
                &services.fleet,
            )
            .await;
        }
        return Ok(());
    }
    session
        .writer
        .try_send_control_json(&CoordinatorControlMessage::TerminalAck(TerminalAck {
            identity: terminal.identity.clone(),
            terminal_digest: terminal.terminal_digest,
            disposition: resolution.disposition(),
        }))?;
    Ok(())
}

fn durable_terminal_disposition(
    disposition: crate::ledger::DurableTerminalDisposition,
) -> Option<darkbloom_coordinator_protocol::v2::TerminalDisposition> {
    use crate::ledger::DurableTerminalDisposition as Durable;
    use darkbloom_coordinator_protocol::v2::TerminalDisposition as Wire;
    match disposition {
        Durable::Settled => Some(Wire::Settled),
        Durable::Released => Some(Wire::Released),
        Durable::SettledReviewed => Some(Wire::SettledReviewed),
        Durable::ReleasedReviewed => Some(Wire::ReleasedReviewed),
        Durable::Late => Some(Wire::Late),
        Durable::Conflict => None,
        Durable::ReviewPending => None,
    }
}

async fn terminal_epoch_is_trusted(
    ledger: &crate::ledger::LedgerService,
    terminal: &ProviderTerminal,
    transport: SessionIdentity,
    services: &ProviderServices,
) -> Result<bool, ProviderEventError> {
    let provider_id = Uuid::from_bytes(*terminal.identity.provider_id.as_bytes());
    let epoch = crate::ledger::Version::new(terminal.identity.session_epoch.0)
        .map_err(crate::ledger::LedgerError::Invalid)?;
    match ledger.ensure_provider_trusted(provider_id, epoch).await {
        Ok(()) => Ok(true),
        Err(crate::ledger::LedgerError::ProviderHardUntrusted) => {
            fence_provider(
                transport,
                "historical terminal came from a hard-untrusted provider epoch",
                &services.directory,
                &services.requests,
                &services.fleet,
            )
            .await;
            Ok(false)
        }
        Err(error) => Err(error.into()),
    }
}

fn recovery_terminal_facts(
    terminal: &ProviderTerminal,
) -> Result<crate::ledger::TerminalFacts, ProviderEventError> {
    use darkbloom_coordinator_protocol::v2::{
        StructuredErrorClass, TerminalOutcome as WireOutcome,
    };

    let mut terminal_id = [0_u8; 16];
    terminal_id.copy_from_slice(&terminal.terminal_digest.as_bytes()[..16]);
    terminal_id[6] = (terminal_id[6] & 0x0f) | 0x40;
    terminal_id[8] = (terminal_id[8] & 0x3f) | 0x80;
    let error_class = terminal.error_class.map(|class| {
        Arc::<str>::from(match class {
            StructuredErrorClass::InvalidRequest => "invalid_request",
            StructuredErrorClass::Capacity => "capacity",
            StructuredErrorClass::ModelNotReady => "model_not_ready",
            StructuredErrorClass::Draining => "draining",
            StructuredErrorClass::Cancelled => "cancelled",
            StructuredErrorClass::Fault => "fault",
            StructuredErrorClass::Security => "security",
        })
    });
    Ok(crate::ledger::TerminalFacts {
        terminal_id: crate::ledger::TerminalId::new(Uuid::from_bytes(terminal_id))
            .map_err(crate::ledger::LedgerError::Invalid)?,
        attempt_id: crate::ledger::AttemptId::new(Uuid::from_bytes(
            *terminal.identity.attempt_id.as_bytes(),
        ))
        .map_err(crate::ledger::LedgerError::Invalid)?,
        provider_id: Uuid::from_bytes(*terminal.identity.provider_id.as_bytes()),
        provider_process_generation_id: Uuid::from_bytes(
            *terminal.identity.provider_process_generation.as_bytes(),
        ),
        origin_session_epoch: crate::ledger::Version::new(terminal.identity.session_epoch.0)
            .map_err(crate::ledger::LedgerError::Invalid)?,
        terminal_digest: darkbloom_coordinator_core::ids::Digest::new(
            *terminal.terminal_digest.as_bytes(),
        ),
        raw_terminal: serde_json::to_value(terminal)?,
        outcome: match terminal.outcome {
            WireOutcome::Completed => crate::ledger::TerminalOutcome::Completed,
            WireOutcome::Cancelled => crate::ledger::TerminalOutcome::Cancelled,
            WireOutcome::Error => crate::ledger::TerminalOutcome::Error,
        },
        error_class,
        // Conflict evidence keeps the exact signed terminal in raw_terminal.
        // Numeric columns are bounded to their schema representation so a
        // malicious u64 counter can still be durably quarantined and reviewed.
        prompt_tokens: terminal.prompt_tokens.min(i32::MAX as u64),
        // The separate accepted checkpoint remains zero after a crash, so
        // recovery cannot use provider-reported tokens to increase the charge.
        completion_tokens: terminal.completion_tokens.min(i32::MAX as u64),
        reasoning_tokens: terminal.reasoning_tokens.min(i64::MAX as u64),
        response_digest: darkbloom_coordinator_core::ids::Digest::new(
            *terminal.response_hash.as_bytes(),
        ),
        rolling_digest: darkbloom_coordinator_core::ids::Digest::new(
            *terminal.rolling_digest.as_bytes(),
        ),
        final_generated_tokens: terminal.final_generated_tokens.min(i64::MAX as u64),
        provider_signature: terminal.signature.as_bytes().to_vec(),
        recovery_lease: None,
    })
}

async fn retry_session_replay(
    session: PilotSession,
    services: &ProviderServices,
) -> Result<(), ProviderEventError> {
    if let Err(error) = repair_replay_obligations(session.identity, services).await {
        if replay_error_is_provider_local(&error) {
            tracing::warn!(
                provider_id = %session.identity.provider_id,
                error = %error,
                "provider replay obligation remains fail-closed"
            );
        } else {
            return Err(error.into());
        }
    }
    if let Err(error) = send_replay_batch(&session, services).await {
        if matches!(&error, ProviderEventError::Writer(_)) {
            fence_provider(
                session.identity,
                "provider replay proof writer failed locally",
                &services.directory,
                &services.requests,
                &services.fleet,
            )
            .await;
            return Ok(());
        }
        if matches!(
            &error,
            ProviderEventError::Replay(replay) if replay_error_is_provider_local(replay)
        ) {
            tracing::warn!(
                provider_id = %session.identity.provider_id,
                error = %error,
                "provider replay retry remains control-only"
            );
            return Ok(());
        }
        return Err(error);
    }
    Ok(())
}

async fn send_replay_batch(
    session: &PilotSession,
    services: &ProviderServices,
) -> Result<(), ProviderEventError> {
    if !session.is_v2() {
        return Ok(());
    }
    let replay_store = services.replay_store.clone();
    let provider_id = session.identity.provider_id;
    let controls = services
        .durable_io
        .run("advance replay retries", move || {
            replay_store.control_batch_for_provider(provider_id, REPLAY_BATCH_SIZE)
        })
        .await
        .map_err(ReplayStoreError::IoPool)??;
    for control in controls {
        session.writer.try_send_control_json(&control.message)?;
    }
    Ok(())
}

pub async fn apply_lifecycle(
    session: &PilotSession,
    fleet: &FleetHandle,
) -> Result<(), FleetHandleError> {
    let context = session.fence.model_id.clone();
    let provider = ProviderSnapshot::new(
        session.fence.clone(),
        HardwareClass::new("apple-silicon").expect("constant hardware class"),
        ProviderTraits::new(TokenCount::new(32_768), [], session.model_eligible),
        CapacitySnapshot::new(
            provider_capacity().token_capacity(),
            TokenCount::ZERO,
            provider_capacity().kv_capacity(),
            KvBytes::ZERO,
            provider_capacity().concurrency_limit(),
            0,
        )
        .expect("constant capacity"),
        HealthState::new(),
    );
    let headroom = session.writer.headroom();
    let writer = WriterHeadroom::new(
        headroom.revision,
        headroom.available_items,
        headroom.available_bytes,
    )
    .expect("provider writer revisions begin at one");
    fleet
        .apply_lifecycle(ProviderLifecycle::new(provider, writer))
        .await?;
    tracing::debug!(model = %context, provider_id = %session.identity.provider_id, "provider entered pilot fleet");
    Ok(())
}

fn provider_capacity() -> ProviderCapacity {
    ProviderCapacity::new(
        TokenCount::new(262_144),
        KvBytes::new(16 * 1024 * 1024 * 1024),
        256,
    )
    .expect("constant provider capacity")
}

async fn remove_fleet(identity: SessionIdentity, fleet: &FleetHandle) {
    let Some(revision) = SessionRevision::new(identity.session_epoch.0).ok() else {
        return;
    };
    match fleet
        .remove_provider(core_provider_id(identity.provider_id), revision)
        .await
    {
        Ok(_) | Err(FleetHandleError::Command(FleetCommandError::ProviderNotFound(_))) => {}
        Err(error) => {
            tracing::warn!(error = %error, provider_id = %identity.provider_id, "pilot fleet removal failed");
        }
    }
}

pub(super) async fn fence_provider(
    identity: SessionIdentity,
    reason: &'static str,
    directory: &SessionDirectory,
    requests: &RequestTable,
    fleet: &FleetHandle,
) {
    if directory.fence_if_current(identity, reason).is_some() {
        requests.cancel_session(identity);
        remove_fleet(identity, fleet).await;
    }
}

fn session_id(identity: SessionIdentity) -> SessionId {
    let mut digest = Sha256::new();
    digest.update(identity.provider_id.as_bytes());
    digest.update(identity.provider_process_generation.as_bytes());
    digest.update(identity.session_epoch.0.to_be_bytes());
    let digest = digest.finalize();
    let mut bytes = [0_u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    if bytes == [0; 16] {
        bytes[15] = 1;
    }
    SessionId::new(Uuid::from_bytes(bytes)).expect("derived session identity is nonzero")
}

fn replay_error_is_provider_local(error: &ReplayStoreError) -> bool {
    matches!(
        error,
        ReplayStoreError::ProviderLimit { .. }
            | ReplayStoreError::GenerationLimit { .. }
            | ReplayStoreError::ProofLimit { .. }
            | ReplayStoreError::ObligationLimit { .. }
            | ReplayStoreError::ProofConflict { .. }
            | ReplayStoreError::MissingObligation { .. }
            | ReplayStoreError::InvalidObligation
            | ReplayStoreError::RetryCountExhausted { .. }
            | ReplayStoreError::Durable(_)
            | ReplayStoreError::IoPool(_)
    )
}

async fn handle_route_error(
    transport: SessionIdentity,
    error: RequestRouteError,
    services: &ProviderServices,
) {
    match error {
        RequestRouteError::Unknown | RequestRouteError::Stale => {}
        RequestRouteError::Closed(_) => {
            tracing::debug!(
                provider_id = %transport.provider_id,
                "provider event arrived after request cancellation"
            );
        }
        RequestRouteError::Authentication(_) => {
            fence_provider(
                transport,
                "provider response authentication failed",
                &services.directory,
                &services.requests,
                &services.fleet,
            )
            .await;
        }
    }
}

async fn require_transport_attempt(
    transport: SessionIdentity,
    attempt: &darkbloom_coordinator_protocol::v2::AttemptIdentity,
    services: &ProviderServices,
) -> bool {
    if !transport.matches_attempt(attempt) {
        fence_provider(
            transport,
            "provider control message carried a foreign session identity",
            &services.directory,
            &services.requests,
            &services.fleet,
        )
        .await;
        return false;
    }
    true
}

async fn require_transport_recovered_attempt(
    transport: SessionIdentity,
    attempt: &darkbloom_coordinator_protocol::v2::AttemptIdentity,
    services: &ProviderServices,
) -> bool {
    if transport.matches_attempt(attempt)
        || (transport.provider_id == attempt.provider_id
            && transport.provider_process_generation == attempt.provider_process_generation
            && transport.session_epoch.0 >= attempt.session_epoch.0)
    {
        return true;
    }
    fence_provider(
        transport,
        "provider recovery control carried a foreign process identity",
        &services.directory,
        &services.requests,
        &services.fleet,
    )
    .await;
    false
}

fn provider_session_matches(
    transport: SessionIdentity,
    identity: &darkbloom_coordinator_protocol::v2::ProviderSessionIdentity,
) -> bool {
    transport.provider_id == identity.provider_id
        && transport.provider_process_generation == identity.process_generation
        && transport.session_epoch == identity.session_epoch
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum ProviderAcceptError {
    #[error("provider session owner is full")]
    Full,
    #[error("provider session owner is unavailable")]
    Closed,
}

#[derive(Debug, Error)]
pub enum ProviderOwnerError {
    #[error("provider owner mailbox closed before shutdown")]
    MailboxClosed,
    #[error("provider session task join failed: {0}")]
    TaskJoin(Arc<str>),
}

#[derive(Debug, Error)]
pub enum ProviderConnectionError {
    #[error(transparent)]
    Reader(#[from] ProviderReadError),
    #[error(transparent)]
    Credential(#[from] crate::trust::CredentialError),
    #[error(transparent)]
    ProcessKey(#[from] crate::crypto::ProcessKeyError),
    #[error(transparent)]
    DurableIo(#[from] crate::crypto::DurableIoError),
    #[error(transparent)]
    EpochStore(#[from] crate::crypto::SessionEpochStoreError),
    #[error("registration did not contain exact signed attestation bytes")]
    MissingAttestation,
    #[error(transparent)]
    Blocking(#[from] crate::trust::BlockingVerificationError),
    #[error(transparent)]
    RegistrationTrust(#[from] crate::trust::RegistrationVerificationError),
    #[error(transparent)]
    ChallengeTrust(#[from] crate::trust::ChallengeVerificationError),
    #[error("attestation challenge failed: {0}")]
    Challenge(Arc<str>),
    #[error("attestation challenge timed out")]
    ChallengeTimeout,
    #[error("provider registration cancelled during shutdown")]
    Shutdown,
    #[error("system clock is before the Unix epoch")]
    Clock,
    #[error(transparent)]
    Reservation(#[from] crate::provider::SessionReservationError),
    #[error(transparent)]
    Session(#[from] crate::provider::ProviderSessionError),
    #[error("provider activation was no longer current")]
    StaleActivation,
    #[error("provider activation serialization timed out")]
    ActivationTimeout,
    #[error("provider activation serialization is unavailable")]
    ActivationClosed,
    #[error("provider lifecycle construction failed: {0}")]
    Lifecycle(Arc<str>),
    #[error(transparent)]
    Fleet(#[from] FleetHandleError),
    #[error(transparent)]
    Replay(#[from] ReplayStoreError),
    #[error(transparent)]
    Event(#[from] ProviderEventError),
    #[error(transparent)]
    Ledger(#[from] crate::ledger::LedgerError),
    #[error(transparent)]
    ProviderControl(#[from] crate::provider_control::ProviderControlError),
}

#[derive(Debug, Error)]
pub enum ProviderEventError {
    #[error("provider event mailbox closed before shutdown")]
    MailboxClosed,
    #[error(transparent)]
    Route(#[from] RequestRouteError),
    #[error(transparent)]
    Replay(#[from] ReplayStoreError),
    #[error(transparent)]
    DurableIo(#[from] crate::crypto::DurableIoError),
    #[error(transparent)]
    Writer(#[from] crate::provider::WriterEnqueueError),
    #[error(transparent)]
    Fleet(#[from] FleetHandleError),
    #[error(transparent)]
    Heartbeat(#[from] HeartbeatPublishError),
    #[error("provider durable event task failed to join: {0}")]
    TaskJoin(Arc<str>),
    #[error("durable terminal service is unavailable")]
    DurableTerminalUnavailable,
    #[error(transparent)]
    Ledger(#[from] crate::ledger::LedgerError),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error(transparent)]
    ProviderControl(#[from] crate::provider_control::ProviderControlError),
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicU64, Ordering};

    use tokio::sync::Notify;

    use super::*;

    #[test]
    fn provider_version_tags_use_only_fixed_floor_buckets() {
        assert_eq!(numeric_version("v0.6.31-dev.1"), Some([0, 6, 31]));
        assert_eq!(numeric_version("1.2.3.4"), None);
        assert_eq!(
            classify_provider_version("0.6.30", "0.6.31", "0.7.5"),
            "below_floor"
        );
        assert_eq!(
            classify_provider_version("0.6.31", "0.6.31", "0.7.5"),
            "older_supported"
        );
        assert_eq!(
            classify_provider_version("0.7.5+build", "0.6.31", "0.7.5"),
            "current"
        );
        assert_eq!(
            classify_provider_version("0.8.0", "0.6.31", "0.7.5"),
            "newer"
        );
        assert_eq!(
            classify_provider_version("0.7.5", "0.6.31", ""),
            "at_or_above_floor"
        );
        assert_eq!(
            classify_provider_version("provider-controlled", "0.6.31", "0.7.5"),
            "invalid"
        );
        assert_eq!(
            classify_provider_version("0.7.5", "", "0.7.5"),
            "unconfigured"
        );
    }

    #[tokio::test]
    async fn paused_older_activation_cannot_publish_after_newer_activation() {
        let gate = ProviderActivationGate::new(Duration::from_secs(1), 2);
        let publication = Arc::new(AtomicU64::new(0));
        let paused = Arc::new(Notify::new());
        let release = Arc::new(Notify::new());

        let older_gate = gate.clone();
        let older_publication = publication.clone();
        let older_paused = paused.clone();
        let older_release = release.clone();
        let paused_wait = paused.notified();
        let older = tokio::spawn(async move {
            let _permit = older_gate.enter().await.expect("older activation permit");
            older_paused.notify_one();
            older_release.notified().await;
            older_publication.store(2, Ordering::Release);
        });
        paused_wait.await;

        let newer_gate = gate.clone();
        let newer_publication = publication.clone();
        let newer = tokio::spawn(async move {
            let _permit = newer_gate.enter().await.expect("newer activation permit");
            assert_eq!(newer_publication.load(Ordering::Acquire), 2);
            newer_publication.store(3, Ordering::Release);
        });
        tokio::task::yield_now().await;
        assert_eq!(publication.load(Ordering::Acquire), 0);
        assert!(!newer.is_finished());

        release.notify_one();
        older.await.expect("older task");
        newer.await.expect("newer task");
        assert_eq!(publication.load(Ordering::Acquire), 3);
    }
}
