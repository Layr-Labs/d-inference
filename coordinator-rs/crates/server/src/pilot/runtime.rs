use std::{fs::File, sync::Arc, time::Duration};

use darkbloom_coordinator_core::{
    ids::{FleetRevision, ModelId},
    money::MicroUsd,
    tokens::TokenCount,
};
use darkbloom_coordinator_protocol::{
    PROTOCOL_V2_MAJOR, crypto::SenderSealEnvelope, v2::ProtocolCapabilities,
};
use sha2::{Digest as _, Sha256};
use subtle::{Choice, ConstantTimeEq};
use thiserror::Error;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

use crate::{
    catalog::{MemoryCatalog, MemoryCatalogError, TextModel},
    crypto::{
        DurableIoConfigError, DurableIoError, DurableIoPool, ProcessKeyError, ProcessX25519Key,
        ReplayProofSigner, ReplayProofStore, ReplaySignerError, ReplayStoreError,
        ReplayStoreLimits, SealKeyringError, SenderSealError, SenderSealKeyring, SessionEpochStore,
        SessionEpochStoreError, TerminalDispositionStore, TerminalStoreError, X25519PublicKey,
    },
    fleet::{FleetActor, FleetActorConfig, FleetConfigError},
    provider::{
        ProviderRegistry, ProviderRegistryConfig, ProviderRegistryConfigError,
        ProviderSessionConfig, SessionEventChannelConfigError, session_event_channel,
    },
    supervisor::{
        EssentialTaskError, SpawnEssentialError, Supervisor, SupervisorConfig,
        SupervisorConfigError, SupervisorError, SupervisorHandle,
    },
    trust::{BoundedBlockingVerifier, CredentialConfigError, CredentialRegistry},
};

use super::{
    config::{PilotConfig, RESPONSE_RESERVATION_BYTES},
    provider::{
        ProviderAcceptor, ProviderActivationGate, ProviderOwner, ProviderServices,
        run_provider_events,
    },
    request::{RequestDispatcher, RequestOwner, RequestServices},
    state::{RequestTable, SessionDirectory},
    telemetry::{PilotTelemetry, PilotTelemetryConfigError},
};

const REPLAY_GENERATIONS_PER_PROVIDER: usize = 8;
const REPLAY_PROOFS_PER_GENERATION: usize = 64;
const TERMINAL_RECORDS_PER_REQUEST: usize = 2;
const TRUST_VERIFICATION_CONCURRENCY: usize = 32;
const DURABLE_IO_CONCURRENCY: usize = 4;
const DURABLE_IO_TIMEOUT: Duration = Duration::from_secs(10);
const PILOT_STARTUP_TIMEOUT: Duration = Duration::from_secs(10);
const PILOT_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(20);
const PILOT_ESSENTIAL_TASKS: usize = 5;
const CONSUMER_KEY_DOMAIN: &[u8] = b"darkbloom.rust-pilot.consumer-key.v1\0";

/// Cloneable ingress and readiness surface for the supervised pilot.
#[derive(Clone)]
pub struct PilotHandle {
    supervisor: SupervisorHandle,
    providers: ProviderAcceptor,
    requests: RequestDispatcher,
    telemetry: PilotTelemetry,
    fleet: crate::fleet::FleetHandle,
    directory: Arc<SessionDirectory>,
    request_table: Arc<RequestTable>,
    keyring: Arc<SenderSealKeyring>,
    catalog: MemoryCatalog,
    consumer_keys: Arc<[[u8; 32]]>,
    input_budget: Arc<ByteBudget>,
    response_budget: Arc<ByteBudget>,
}

impl PilotHandle {
    #[must_use]
    pub fn is_ready(&self) -> bool {
        self.supervisor.is_ready()
    }

    #[must_use]
    pub fn readiness(&self) -> crate::supervisor::SupervisorReadiness {
        self.supervisor.readiness()
    }

    pub async fn changed(
        &mut self,
    ) -> Result<crate::supervisor::SupervisorReadiness, crate::supervisor::SupervisorUnavailable>
    {
        self.supervisor.changed().await
    }

    pub fn shutdown(&self) {
        self.supervisor.shutdown();
    }

    #[must_use]
    pub fn provider_acceptor(&self) -> ProviderAcceptor {
        self.providers.clone()
    }

    #[must_use]
    pub fn request_dispatcher(&self) -> RequestDispatcher {
        self.requests.clone()
    }

    #[must_use]
    pub fn catalog(&self) -> &MemoryCatalog {
        &self.catalog
    }

    #[must_use]
    pub fn keyring(&self) -> &SenderSealKeyring {
        &self.keyring
    }

    #[must_use]
    pub fn authorize_consumer(&self, presented: &str) -> bool {
        let presented = consumer_key_digest(presented.as_bytes());
        let mut matched = Choice::from(0);
        for configured in self.consumer_keys.iter() {
            matched |= configured.ct_eq(&presented);
        }
        bool::from(matched)
    }

    pub fn open_sender(&self, envelope: &SenderSealEnvelope) -> Result<Vec<u8>, SenderSealError> {
        self.keyring.open(envelope)
    }

    pub fn seal_to_sender(
        &self,
        sender: X25519PublicKey,
        plaintext: &[u8],
    ) -> Result<String, SenderSealError> {
        self.keyring.seal_to_sender(sender, plaintext)
    }

    pub fn try_reserve_input(
        &self,
        bytes: usize,
    ) -> Result<OwnedSemaphorePermit, PilotResourceError> {
        self.input_budget
            .try_reserve(bytes)
            .map_err(|_| PilotResourceError::InputCapacity)
    }

    pub fn try_reserve_response(&self) -> Result<OwnedSemaphorePermit, PilotResourceError> {
        self.response_budget
            .try_reserve(RESPONSE_RESERVATION_BYTES)
            .map_err(|_| PilotResourceError::ResponseCapacity)
    }

    #[must_use]
    pub fn visible_provider_count(&self) -> usize {
        self.directory.visible_count()
    }

    #[must_use]
    pub fn inference_provider_count(&self) -> usize {
        self.directory.inference_count()
    }

    #[must_use]
    pub fn active_request_count(&self) -> usize {
        self.request_table.len()
    }

    #[must_use]
    pub fn input_budget_available(&self) -> usize {
        self.input_budget.available_bytes()
    }

    #[must_use]
    pub fn response_budget_available(&self) -> usize {
        self.response_budget.available_bytes()
    }

    #[must_use]
    pub fn telemetry(&self) -> &PilotTelemetry {
        &self.telemetry
    }

    #[must_use]
    pub fn fleet_snapshot(&self) -> Arc<crate::fleet::FleetSnapshot> {
        self.fleet.snapshot()
    }

    #[must_use]
    pub fn fleet_reliable_remaining_capacity(&self) -> usize {
        self.fleet.reliable_remaining_capacity()
    }

    #[cfg(test)]
    pub(crate) fn exhaust_provider_control_capacity_for_test(
        &self,
        provider_id: darkbloom_coordinator_protocol::v2::ProviderId,
    ) -> bool {
        let Some(session) = self.directory.current(provider_id) else {
            return false;
        };
        session.writer.exhaust_control_capacity_for_test();
        true
    }
}

/// Owns the supervisor that joins every essential pilot task.
pub struct PilotRuntime {
    supervisor: Supervisor,
    fleet_lifetime: crate::fleet::FleetHandle,
}

impl PilotRuntime {
    pub async fn build(
        config: &PilotConfig,
    ) -> Result<(Self, PilotHandle), PilotRuntimeBuildError> {
        if !config.enabled {
            return Err(PilotRuntimeBuildError::Disabled);
        }
        let durable_io = DurableIoPool::new(DURABLE_IO_CONCURRENCY, DURABLE_IO_TIMEOUT)?;
        let state_directory = config.state_directory.clone();
        durable_io
            .run("create pilot state directory", move || {
                create_state_directory(&state_directory)
            })
            .await??;

        let process_key = ProcessX25519Key::from_base64(
            config.process_key_id.clone(),
            &config.process_private_key,
            &config.process_public_key,
        )?;
        let keyring = Arc::new(SenderSealKeyring::new(
            config.process_key_id.clone(),
            [process_key],
        )?);
        let replay_signer_path = config.state_directory.join("replay-authority.json");
        let replay_signer = Arc::new(
            durable_io
                .run("open replay authority", move || {
                    ReplayProofSigner::open(replay_signer_path)
                })
                .await??,
        );
        let epoch_path = config.state_directory.join("provider-epochs.json");
        let maximum_sessions = config.maximum_sessions;
        let epoch_store = Arc::new(
            durable_io
                .run("open provider epoch store", move || {
                    SessionEpochStore::open(epoch_path, maximum_sessions)
                })
                .await??,
        );
        let replay_path = config.state_directory.join("replay-proofs.json");
        let replay_limits = ReplayStoreLimits {
            maximum_providers: config.maximum_sessions,
            maximum_generations_per_provider: REPLAY_GENERATIONS_PER_PROVIDER,
            maximum_proofs_per_generation: REPLAY_PROOFS_PER_GENERATION,
        };
        let replay_store = Arc::new(
            durable_io
                .run("open replay proof store", move || {
                    ReplayProofStore::open(replay_path, replay_limits)
                })
                .await??,
        );
        let terminal_capacity = config
            .maximum_requests
            .checked_mul(TERMINAL_RECORDS_PER_REQUEST)
            .ok_or(PilotRuntimeBuildError::ResourceBoundOverflow)?;
        let terminal_path = config.state_directory.join("terminal-dispositions.json");
        let terminal_store = Arc::new(
            durable_io
                .run("open terminal disposition store", move || {
                    TerminalDispositionStore::open(terminal_path, terminal_capacity)
                })
                .await??,
        );
        let credential_path = config.state_directory.join("provider-key-bindings.json");
        let configured_credentials = config.configured_credentials().collect::<Vec<_>>();
        let maximum_sessions = config.maximum_sessions;
        let credentials = durable_io
            .run("open provider credential bindings", move || {
                CredentialRegistry::open(credential_path, maximum_sessions, configured_credentials)
            })
            .await??;
        let trust_verifier = Arc::new(BoundedBlockingVerifier::new(
            TRUST_VERIFICATION_CONCURRENCY.min(config.maximum_sessions),
            config.maximum_sessions,
        )?);

        let catalog = configured_catalog(config)?;
        let replay_public_key: Arc<str> = Arc::from(replay_signer.public_key_base64());
        let registry = Arc::new(ProviderRegistry::new(ProviderRegistryConfig {
            maximum_providers: config.maximum_sessions,
            coordinator_capabilities: complete_v2_capabilities(),
            coordinator_replay_fence_public_key: Some(replay_public_key),
        })?);
        let (events, event_receiver) = session_event_channel(config.session_event_capacity)?;
        let directory = Arc::new(SessionDirectory::new(
            config
                .maximum_sessions
                .checked_mul(REPLAY_GENERATIONS_PER_PROVIDER)
                .ok_or(PilotRuntimeBuildError::ResourceBoundOverflow)?,
        ));
        let request_table = Arc::new(RequestTable::new(config.maximum_requests));
        let (telemetry, telemetry_worker) = PilotTelemetry::new(config.telemetry_capacity)?;

        let mut fleet_config = FleetActorConfig::default();
        fleet_config.maximum_providers = config.maximum_sessions;
        fleet_config.maximum_active_leases = config
            .maximum_requests
            .checked_mul(2)
            .ok_or(PilotRuntimeBuildError::ResourceBoundOverflow)?;
        fleet_config.maximum_writer_debits = fleet_config.maximum_active_leases;
        fleet_config.maximum_lease_ttl = config.permit_lease_ttl;
        fleet_config.reliable_mailbox_capacity = config
            .maximum_requests
            .saturating_add(config.maximum_sessions)
            .max(128);
        fleet_config.reliable_correctness_reserve =
            (fleet_config.reliable_mailbox_capacity / 8).max(8);
        fleet_config.heartbeat_capacity = config.maximum_sessions;
        let (fleet_actor, fleet) = FleetActor::new(
            fleet_config,
            FleetRevision::new(1).expect("one is a valid fleet revision"),
        )?;

        let mut session_config = ProviderSessionConfig::default();
        session_config.writer.control.maximum_items = session_config
            .writer
            .control
            .maximum_items
            .max(config.maximum_requests);
        session_config.writer.data.maximum_items = session_config
            .writer
            .data
            .maximum_items
            .max(config.maximum_requests);
        let request_writer_items = config
            .maximum_requests
            .checked_add(session_config.writer.control_correctness_item_reserve)
            .ok_or(PilotRuntimeBuildError::ResourceBoundOverflow)?;
        session_config.writer.maximum_items = session_config
            .writer
            .maximum_items
            .max(request_writer_items);

        let provider_services = Arc::new(ProviderServices {
            credentials,
            trust_verifier,
            trust_floor: config.trust_floor,
            established_trust: config.established_trust_level(),
            registry,
            events,
            session_config,
            directory: directory.clone(),
            requests: request_table.clone(),
            fleet: fleet.clone(),
            catalog: catalog.clone(),
            replay_signer,
            replay_store,
            terminal_store: terminal_store.clone(),
            epoch_store,
            durable_io: durable_io.clone(),
            activation: ProviderActivationGate::new(
                session_config.registration_timeout,
                config.maximum_sessions,
            ),
            telemetry: telemetry.clone(),
        });
        let (provider_owner, provider_acceptor) =
            ProviderOwner::new(config.maximum_sessions, provider_services.clone());
        let request_services = Arc::new(RequestServices {
            fleet: fleet.clone(),
            directory: directory.clone(),
            requests: request_table.clone(),
            terminal_store,
            durable_io,
            telemetry: telemetry.clone(),
            request_timeout: config.request_timeout,
            permit_lease_ttl: config.permit_lease_ttl,
            maximum_output_bytes: config.maximum_output_bytes,
            maximum_output_chunks: config.maximum_output_chunks,
        });
        let (request_owner, request_dispatcher) = RequestOwner::new(
            config.request_queue_capacity,
            config.maximum_requests,
            request_services,
        );

        let (mut supervisor, supervisor_handle) = Supervisor::new(SupervisorConfig {
            startup_timeout: PILOT_STARTUP_TIMEOUT,
            shutdown_timeout: PILOT_SHUTDOWN_TIMEOUT,
            maximum_tasks: PILOT_ESSENTIAL_TASKS,
        })?;
        supervisor.spawn_essential("pilot-fleet", move |context| async move {
            context
                .mark_ready()
                .map_err(|error| EssentialTaskError::new(error.to_string()))?;
            fleet_actor
                .run(context.cancellation_token())
                .await
                .map_err(|error| EssentialTaskError::new(error.to_string()))
        })?;
        supervisor.spawn_essential("pilot-provider-owner", move |context| async move {
            context
                .mark_ready()
                .map_err(|error| EssentialTaskError::new(error.to_string()))?;
            provider_owner
                .run(context.cancellation_token())
                .await
                .map_err(|error| EssentialTaskError::new(error.to_string()))
        })?;
        supervisor.spawn_essential("pilot-provider-events", move |context| async move {
            context
                .mark_ready()
                .map_err(|error| EssentialTaskError::new(error.to_string()))?;
            run_provider_events(
                event_receiver,
                provider_services,
                context.cancellation_token(),
            )
            .await
            .map_err(|error| EssentialTaskError::new(error.to_string()))
        })?;
        supervisor.spawn_essential("pilot-request-owner", move |context| async move {
            context
                .mark_ready()
                .map_err(|error| EssentialTaskError::new(error.to_string()))?;
            request_owner
                .run(context.cancellation_token())
                .await
                .map_err(|error| EssentialTaskError::new(error.to_string()))
        })?;
        supervisor.spawn_essential("pilot-telemetry", move |context| async move {
            context
                .mark_ready()
                .map_err(|error| EssentialTaskError::new(error.to_string()))?;
            telemetry_worker
                .run(context.cancellation_token())
                .await
                .map_err(|error| EssentialTaskError::new(error.to_string()))
        })?;

        let handle = PilotHandle {
            supervisor: supervisor_handle,
            providers: provider_acceptor,
            requests: request_dispatcher,
            telemetry,
            fleet: fleet.clone(),
            directory,
            request_table,
            keyring,
            catalog,
            consumer_keys: consumer_key_digests(&config.consumer_api_keys)?,
            input_budget: Arc::new(ByteBudget::new(
                config.input_budget_bytes,
                super::config::INPUT_RESERVATION_BYTES,
            )),
            response_budget: Arc::new(ByteBudget::new(
                config.response_budget_bytes,
                RESPONSE_RESERVATION_BYTES,
            )),
        };
        Ok((
            Self {
                supervisor,
                fleet_lifetime: fleet,
            },
            handle,
        ))
    }

    pub async fn run(self) -> Result<(), SupervisorError> {
        let Self {
            supervisor,
            fleet_lifetime,
        } = self;
        let result = supervisor.run().await;
        drop(fleet_lifetime);
        result
    }
}

fn configured_catalog(config: &PilotConfig) -> Result<MemoryCatalog, PilotRuntimeBuildError> {
    let model = ModelId::new(config.model_id.as_ref())
        .map_err(|error| PilotRuntimeBuildError::Model(Arc::from(error.to_string())))?;
    let text = TextModel::new(
        model,
        [config.model_alias.clone()],
        TokenCount::new(32_768),
        MicroUsd::new(50_000),
        MicroUsd::new(200_000),
    )?;
    Ok(MemoryCatalog::new(text))
}

fn complete_v2_capabilities() -> ProtocolCapabilities {
    ProtocolCapabilities {
        protocol_major: PROTOCOL_V2_MAJOR,
        protocol_minor: 0,
        minimum_compatible_minor: 0,
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
    }
}

fn create_state_directory(path: &std::path::Path) -> Result<(), std::io::Error> {
    std::fs::create_dir_all(path)?;
    File::open(path)?.sync_all()?;
    Ok(())
}

fn consumer_key_digests(keys: &[Arc<str>]) -> Result<Arc<[[u8; 32]]>, PilotRuntimeBuildError> {
    let mut digests = Vec::with_capacity(keys.len());
    for key in keys {
        let digest = consumer_key_digest(key.as_bytes());
        if digests.iter().any(|existing| existing == &digest) {
            return Err(PilotRuntimeBuildError::DuplicateConsumerKey);
        }
        digests.push(digest);
    }
    Ok(digests.into())
}

fn consumer_key_digest(key: &[u8]) -> [u8; 32] {
    let mut digest = Sha256::new();
    digest.update(CONSUMER_KEY_DOMAIN);
    digest.update(key);
    digest.finalize().into()
}

#[derive(Debug)]
struct ByteBudget {
    total_bytes: usize,
    reservation_bytes: usize,
    slots: Arc<Semaphore>,
}

impl ByteBudget {
    fn new(total_bytes: usize, reservation_bytes: usize) -> Self {
        debug_assert!(reservation_bytes > 0);
        Self {
            total_bytes,
            reservation_bytes,
            slots: Arc::new(Semaphore::new(total_bytes / reservation_bytes)),
        }
    }

    fn try_reserve(
        &self,
        requested_bytes: usize,
    ) -> Result<OwnedSemaphorePermit, tokio::sync::TryAcquireError> {
        if requested_bytes == 0 || requested_bytes > self.reservation_bytes {
            return Err(tokio::sync::TryAcquireError::NoPermits);
        }
        self.slots.clone().try_acquire_owned()
    }

    fn available_bytes(&self) -> usize {
        self.slots
            .available_permits()
            .saturating_mul(self.reservation_bytes)
            .saturating_add(self.total_bytes % self.reservation_bytes)
    }
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum PilotResourceError {
    #[error("pilot global input budget is exhausted")]
    InputCapacity,
    #[error("pilot global response budget is exhausted")]
    ResponseCapacity,
}

#[derive(Debug, Error)]
pub enum PilotRuntimeBuildError {
    #[error("pilot runtime cannot be built while disabled")]
    Disabled,
    #[error("pilot resource bound arithmetic overflow")]
    ResourceBoundOverflow,
    #[error("pilot consumer API keys must be unique")]
    DuplicateConsumerKey,
    #[error("invalid pilot model: {0}")]
    Model(Arc<str>),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    DurableIoConfig(#[from] DurableIoConfigError),
    #[error(transparent)]
    DurableIo(#[from] DurableIoError),
    #[error(transparent)]
    ProcessKey(#[from] ProcessKeyError),
    #[error(transparent)]
    SealKeyring(#[from] SealKeyringError),
    #[error(transparent)]
    ReplaySigner(#[from] ReplaySignerError),
    #[error(transparent)]
    EpochStore(#[from] SessionEpochStoreError),
    #[error(transparent)]
    ReplayStore(#[from] ReplayStoreError),
    #[error(transparent)]
    TerminalStore(#[from] TerminalStoreError),
    #[error(transparent)]
    Credential(#[from] CredentialConfigError),
    #[error(transparent)]
    Trust(#[from] crate::trust::BlockingVerificationError),
    #[error(transparent)]
    Catalog(#[from] MemoryCatalogError),
    #[error(transparent)]
    Registry(#[from] ProviderRegistryConfigError),
    #[error(transparent)]
    Events(#[from] SessionEventChannelConfigError),
    #[error(transparent)]
    Telemetry(#[from] PilotTelemetryConfigError),
    #[error(transparent)]
    Fleet(#[from] FleetConfigError),
    #[error(transparent)]
    SupervisorConfig(#[from] SupervisorConfigError),
    #[error(transparent)]
    Spawn(#[from] SpawnEssentialError),
}
