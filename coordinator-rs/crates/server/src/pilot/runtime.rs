use std::{fs::File, sync::Arc, time::Duration};

use darkbloom_coordinator_core::{
    ids::{FleetRevision, ModelId},
    money::MicroUsd,
    tokens::TokenCount,
};
use darkbloom_coordinator_protocol::{
    PROTOCOL_V2_MAJOR, crypto::SenderSealEnvelope, v2::ProtocolCapabilities,
};
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
    ledger::LedgerService,
    ownership::OwnershipStatus,
    provider::{
        ProviderRegistry, ProviderRegistryConfig, ProviderRegistryConfigError,
        ProviderSessionConfig, SessionEventChannelConfigError, session_event_channel,
    },
    provider_control::ProviderControlPlane,
    supervisor::{
        EssentialTaskError, SpawnEssentialError, Supervisor, SupervisorConfig,
        SupervisorConfigError, SupervisorError, SupervisorHandle,
    },
    trust::{BoundedBlockingVerifier, CredentialConfigError, CredentialRegistry},
};

use super::{
    billing::{BillingConfigurationError, BillingContext, ConsumerCredential, PilotBilling},
    config::{PilotConfig, RESPONSE_RESERVATION_BYTES},
    provider::{
        ProviderAcceptor, ProviderActivationGate, ProviderOwner, ProviderServices, fence_provider,
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
    consumer_credentials: Arc<[ConsumerCredential]>,
    input_budget: Arc<ByteBudget>,
    response_budget: Arc<ByteBudget>,
    attempt_queries: Arc<super::reconciliation::AttemptQueryRegistry>,
    provider_control: Option<ProviderControlPlane>,
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
    pub fn provider_control(&self) -> Option<ProviderControlPlane> {
        self.provider_control.clone()
    }

    pub async fn fence_provider_epoch(
        &self,
        provider_id: darkbloom_coordinator_protocol::v2::ProviderId,
        session_epoch: darkbloom_coordinator_protocol::v2::SessionEpoch,
        reason: &'static str,
    ) {
        let Some(session) = self.directory.current(provider_id) else {
            return;
        };
        if session.identity.session_epoch != session_epoch {
            return;
        }
        fence_provider(
            session.identity,
            reason,
            &self.directory,
            &self.request_table,
            &self.fleet,
        )
        .await;
    }

    pub async fn fence_provider(
        &self,
        provider_id: darkbloom_coordinator_protocol::v2::ProviderId,
        reason: &'static str,
    ) {
        let Some(session) = self.directory.current(provider_id) else {
            return;
        };
        fence_provider(
            session.identity,
            reason,
            &self.directory,
            &self.request_table,
            &self.fleet,
        )
        .await;
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
    pub fn authorize_consumer(&self, presented: &str) -> Option<BillingContext> {
        ConsumerCredential::authenticate(&self.consumer_credentials, presented)
    }

    /// Queries the currently connected stable provider for durable knowledge
    /// of one exact historical attempt.
    pub async fn query_recovered_attempt(
        &self,
        lease: &crate::recovery::JobRecoveryLease,
    ) -> Result<Option<darkbloom_coordinator_protocol::v2::AttemptStatus>, Arc<str>> {
        let attempt = lease
            .attempt
            .as_ref()
            .ok_or_else(|| Arc::from("authorized recovery job has no durable attempt"))?;
        let provider_id =
            darkbloom_coordinator_protocol::v2::ProviderId::new(*attempt.provider_id.as_bytes());
        let Some(session) = self.directory.current(provider_id) else {
            return Ok(None);
        };
        let identity = recovery_attempt_identity(lease, attempt)?;
        self.attempt_queries
            .query(&session, identity, Duration::from_secs(5))
            .await
            .map(Some)
    }

    /// Re-sends Start only to the exact durable provider process and lease.
    /// A reconnect from that same process generation may carry a newer session
    /// epoch; the Start itself retains the historical attempt identity.
    pub fn stage_recovered_start(
        &self,
        lease: &crate::recovery::JobRecoveryLease,
    ) -> Result<Option<crate::provider::StagedDelivery>, Arc<str>> {
        let attempt = lease
            .attempt
            .as_ref()
            .ok_or_else(|| Arc::from("authorized recovery job has no durable attempt"))?;
        let provider_id =
            darkbloom_coordinator_protocol::v2::ProviderId::new(*attempt.provider_id.as_bytes());
        let Some(session) = self.directory.current(provider_id) else {
            return Ok(None);
        };
        if !recovery_session_can_resume(&session.identity, attempt)? {
            return Ok(None);
        }
        let identity = recovery_attempt_identity(lease, attempt)?;
        let staged = session
            .writer
            .try_stage_control_json(
                &darkbloom_coordinator_protocol::v2::CoordinatorControlMessage::Start(
                    darkbloom_coordinator_protocol::v2::Start { identity },
                ),
            )
            .map_err(|error| Arc::from(error.to_string()))?;
        Ok(Some(staged))
    }

    /// Sends a terminal ACK only after the recovery worker has committed the
    /// matching database disposition. A disconnected or superseded session is
    /// harmless: the provider's replay will use the database lookup path.
    pub async fn ack_recovered_terminal(
        &self,
        lease: &crate::recovery::TerminalRecoveryLease,
        disposition: crate::recovery::RecoveredTerminalDisposition,
    ) -> Result<(), Arc<str>> {
        let terminal: darkbloom_coordinator_protocol::v2::ProviderTerminal =
            serde_json::from_value(lease.raw_terminal.clone())
                .map_err(|error| Arc::from(error.to_string()))?;
        if terminal.identity.attempt_id.as_bytes() != lease.attempt_id.as_uuid().as_bytes()
            || terminal.identity.provider_id.as_bytes() != lease.provider_id.as_bytes()
            || terminal.identity.provider_process_generation.as_bytes()
                != lease.provider_process_generation_id.as_bytes()
            || terminal.identity.session_epoch.0
                != u64::try_from(lease.origin_session_epoch.as_i64())
                    .map_err(|_| Arc::from("negative terminal session epoch"))?
            || terminal.terminal_digest.as_bytes() != lease.terminal_digest.as_bytes()
        {
            return Err(Arc::from(
                "recovered terminal JSON differs from its durable identity",
            ));
        }
        let Some(session) = self.directory.current(terminal.identity.provider_id) else {
            return Ok(());
        };
        let disposition = match disposition {
            crate::recovery::RecoveredTerminalDisposition::Settled => {
                darkbloom_coordinator_protocol::v2::TerminalDisposition::Settled
            }
            crate::recovery::RecoveredTerminalDisposition::Released => {
                darkbloom_coordinator_protocol::v2::TerminalDisposition::Released
            }
        };
        let receipt = session
            .writer
            .try_send_control_json(
                &darkbloom_coordinator_protocol::v2::CoordinatorControlMessage::TerminalAck(
                    darkbloom_coordinator_protocol::v2::TerminalAck {
                        identity: terminal.identity,
                        terminal_digest: terminal.terminal_digest,
                        disposition,
                    },
                ),
            )
            .map_err(|error| Arc::from(error.to_string()))?;
        match receipt
            .wait()
            .await
            .map_err(|error| Arc::from(error.to_string()))?
        {
            crate::provider::DeliveryState::OnWire
            | crate::provider::DeliveryState::SentUnknown => Ok(()),
            crate::provider::DeliveryState::Queued => {
                Err(Arc::from("terminal ACK receipt remained queued"))
            }
            crate::provider::DeliveryState::Failed(error) => Err(error),
        }
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
    pub fn provider_protocol_counts(&self) -> (usize, usize, usize) {
        self.directory.protocol_counts()
    }

    #[must_use]
    pub fn provider_trust_counts(&self) -> (usize, usize, usize) {
        self.directory.trust_counts()
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

fn recovery_session_can_resume(
    session: &crate::provider::SessionIdentity,
    attempt: &crate::recovery::AuthorizedAttemptRecovery,
) -> Result<bool, Arc<str>> {
    let historical_epoch = u64::try_from(attempt.session_epoch.as_i64())
        .map_err(|_| Arc::from("negative durable provider session epoch"))?;
    Ok(session.provider_process_generation.as_bytes()
        == attempt.provider_process_generation_id.as_bytes()
        && session.session_epoch.0 >= historical_epoch)
}

fn recovery_attempt_identity(
    lease: &crate::recovery::JobRecoveryLease,
    attempt: &crate::recovery::AuthorizedAttemptRecovery,
) -> Result<darkbloom_coordinator_protocol::v2::AttemptIdentity, Arc<str>> {
    Ok(darkbloom_coordinator_protocol::v2::AttemptIdentity {
        provider_id: darkbloom_coordinator_protocol::v2::ProviderId::new(
            *attempt.provider_id.as_bytes(),
        ),
        provider_process_generation:
            darkbloom_coordinator_protocol::v2::ProviderProcessGenerationId::new(
                *attempt.provider_process_generation_id.as_bytes(),
            ),
        session_epoch: darkbloom_coordinator_protocol::v2::SessionEpoch(
            u64::try_from(attempt.session_epoch.as_i64())
                .map_err(|_| Arc::from("negative durable provider session epoch"))?,
        ),
        request_id: darkbloom_coordinator_protocol::v2::RequestId::new(
            *lease.request_id.as_bytes(),
        ),
        attempt_id: darkbloom_coordinator_protocol::v2::AttemptId::new(
            *attempt.attempt_id.as_uuid().as_bytes(),
        ),
        reservation_id: darkbloom_coordinator_protocol::v2::ReservationId::new(
            *lease.reservation_id.as_bytes(),
        ),
        lease_id: darkbloom_coordinator_protocol::v2::LeaseId::new(*attempt.lease_id.as_bytes()),
    })
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
        Self::build_inner(config, None).await
    }

    pub async fn build_durable(
        config: &PilotConfig,
        database: crate::database::Database,
        ownership: OwnershipStatus,
    ) -> Result<(Self, PilotHandle), PilotRuntimeBuildError> {
        Self::build_durable_inner(config, database, ownership, None).await
    }

    pub async fn build_durable_with_admission(
        config: &PilotConfig,
        database: crate::database::Database,
        ownership: OwnershipStatus,
        admission: crate::surface::operations::AdmissionGate,
    ) -> Result<(Self, PilotHandle), PilotRuntimeBuildError> {
        Self::build_durable_inner(config, database, ownership, Some(admission)).await
    }

    async fn build_durable_inner(
        config: &PilotConfig,
        database: crate::database::Database,
        ownership: OwnershipStatus,
        admission: Option<crate::surface::operations::AdmissionGate>,
    ) -> Result<(Self, PilotHandle), PilotRuntimeBuildError> {
        if !ownership.is_healthy() {
            return Err(PilotRuntimeBuildError::OwnershipUnavailable);
        }
        let billing = config
            .paid_billing
            .clone()
            .map(|policy| PilotBilling::new(policy, config.provider_beneficiaries.clone()))
            .transpose()?;
        let provider_control = config
            .mdm_control
            .clone()
            .map(|mdm| {
                let control = ProviderControlPlane::new(
                    database.clone(),
                    config.configured_provider_identities()?,
                    mdm,
                )?;
                Ok::<_, PilotRuntimeBuildError>(
                    admission
                        .clone()
                        .map_or(control.clone(), |gate| control.with_admission_gate(gate)),
                )
            })
            .transpose()?;
        let ledger = LedgerService::new(database);
        Self::build_inner(
            config,
            Some(DurablePilotServices {
                ledger,
                billing,
                ownership,
                provider_control,
            }),
        )
        .await
    }

    async fn build_inner(
        config: &PilotConfig,
        durable: Option<DurablePilotServices>,
    ) -> Result<(Self, PilotHandle), PilotRuntimeBuildError> {
        if !config.enabled {
            return Err(PilotRuntimeBuildError::Disabled);
        }
        let public_durability = durable.as_ref().is_some_and(|services| {
            if config.dynamic_controls {
                services.provider_control.is_some()
            } else {
                services.billing.is_some()
            }
        });
        if config.trust_floor == crate::trust::TrustFloor::PUBLIC && !public_durability {
            return Err(PilotRuntimeBuildError::PublicDurabilityRequired);
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
        let attempt_queries = Arc::new(super::reconciliation::AttemptQueryRegistry::new(
            config.maximum_requests,
        ));

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
            ledger: durable.as_ref().map(|services| services.ledger.clone()),
            durable_terminals: durable.is_some(),
            attempt_queries: attempt_queries.clone(),
            provider_control: durable
                .as_ref()
                .and_then(|services| services.provider_control.clone()),
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
            durable: durable.clone(),
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
            consumer_credentials: ConsumerCredential::configured(
                &config.consumer_credentials,
                static_paid_consumer_mode(config),
            )?,
            input_budget: Arc::new(ByteBudget::new(
                config.input_budget_bytes,
                super::config::INPUT_RESERVATION_BYTES,
            )),
            response_budget: Arc::new(ByteBudget::new(
                config.response_budget_bytes,
                RESPONSE_RESERVATION_BYTES,
            )),
            attempt_queries,
            provider_control: durable.and_then(|services| services.provider_control),
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

fn static_paid_consumer_mode(config: &PilotConfig) -> bool {
    config.paid_billing.is_some() || config.trust_floor == crate::trust::TrustFloor::PUBLIC
}

#[derive(Clone)]
pub(crate) struct DurablePilotServices {
    pub ledger: LedgerService,
    pub billing: Option<PilotBilling>,
    pub ownership: OwnershipStatus,
    pub provider_control: Option<ProviderControlPlane>,
}

fn configured_catalog(config: &PilotConfig) -> Result<MemoryCatalog, PilotRuntimeBuildError> {
    let model = ModelId::new(config.model_id.as_ref())
        .map_err(|error| PilotRuntimeBuildError::Model(Arc::from(error.to_string())))?;
    let (input_price, output_price) = config.paid_billing.as_ref().map_or(
        (MicroUsd::new(50_000), MicroUsd::new(200_000)),
        |policy| {
            (
                MicroUsd::new(
                    u64::try_from(policy.input_micro_usd_per_million.as_i64())
                        .expect("ledger amounts are nonnegative"),
                ),
                MicroUsd::new(
                    u64::try_from(policy.output_micro_usd_per_million.as_i64())
                        .expect("ledger amounts are nonnegative"),
                ),
            )
        },
    );
    let text = TextModel::new(
        model,
        [config.model_alias.clone()],
        TokenCount::new(32_768),
        input_price,
        output_price,
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
        attempt_reconciliation: true,
    }
}

fn create_state_directory(path: &std::path::Path) -> Result<(), std::io::Error> {
    std::fs::create_dir_all(path)?;
    File::open(path)?.sync_all()?;
    Ok(())
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
    #[error(
        "public pilot mode requires durable ownership plus database controls and hardware provider control"
    )]
    PublicDurabilityRequired,
    #[error("pilot durable ownership is unavailable")]
    OwnershipUnavailable,
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
    #[error(transparent)]
    Billing(#[from] BillingConfigurationError),
    #[error(transparent)]
    ProviderControl(#[from] crate::provider_control::ProviderControlError),
    #[error(transparent)]
    Config(#[from] super::config::PilotConfigError),
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        ledger::{AccountId, AttemptId, AttemptState, LedgerAmount, Version},
        pilot::PaidBillingPolicy,
        recovery::AuthorizedAttemptRecovery,
    };

    #[test]
    fn paid_catalog_advertises_the_exact_configured_rates() {
        let mut config = PilotConfig::disabled();
        config.paid_billing = Some(PaidBillingPolicy {
            platform_account_id: AccountId::new("platform").expect("account"),
            referral_account_id: None,
            pricing_version: Version::new(3).expect("version"),
            rounding_version: Version::new(2).expect("version"),
            base_reservation: LedgerAmount::new(1).expect("amount"),
            input_micro_usd_per_million: LedgerAmount::new(123).expect("amount"),
            output_micro_usd_per_million: LedgerAmount::new(456).expect("amount"),
            provider_share_ppm: 800_000,
            referral_share_ppm: 0,
        });

        let catalog = configured_catalog(&config).expect("catalog");
        let model = catalog.models().next().expect("model");
        assert_eq!(model.input_micro_usd_per_million.get(), 123);
        assert_eq!(model.output_micro_usd_per_million.get(), 456);
        assert!(static_paid_consumer_mode(&config));
    }

    #[test]
    fn recovery_start_accepts_only_same_process_reconnects() {
        let provider_id = uuid::Uuid::new_v4();
        let generation_id = uuid::Uuid::new_v4();
        let attempt = AuthorizedAttemptRecovery {
            attempt_id: AttemptId::random(),
            provider_id,
            provider_process_generation_id: generation_id,
            session_epoch: Version::new(7).expect("session epoch"),
            lease_id: uuid::Uuid::new_v4(),
            state: AttemptState::Queued,
            version: Version::new(1).expect("attempt version"),
        };
        let session = |generation: uuid::Uuid, epoch| crate::provider::SessionIdentity {
            provider_id: darkbloom_coordinator_protocol::v2::ProviderId::new(
                *provider_id.as_bytes(),
            ),
            provider_process_generation:
                darkbloom_coordinator_protocol::v2::ProviderProcessGenerationId::new(
                    *generation.as_bytes(),
                ),
            session_epoch: darkbloom_coordinator_protocol::v2::SessionEpoch(epoch),
        };

        assert!(
            recovery_session_can_resume(&session(generation_id, 7), &attempt)
                .expect("same session")
        );
        assert!(
            recovery_session_can_resume(&session(generation_id, 8), &attempt)
                .expect("same-process reconnect")
        );
        assert!(
            !recovery_session_can_resume(&session(generation_id, 6), &attempt)
                .expect("older session")
        );
        assert!(
            !recovery_session_can_resume(&session(uuid::Uuid::new_v4(), 8), &attempt)
                .expect("new process generation")
        );
    }
}
