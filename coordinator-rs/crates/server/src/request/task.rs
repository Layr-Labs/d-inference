//! One logical request job driven by the pure core reducer.

use std::{collections::BTreeMap, sync::Arc};

use darkbloom_coordinator_core::{
    deadline::{AbsoluteDeadline, EpochMillis},
    ids::{
        AttemptId as CoreAttemptId, Digest as CoreDigest, EventId, LeaseId as CoreLeaseId, ModelId,
        PermitId, RequestId as CoreRequestId,
    },
    money::MicroUsd,
    request::{
        AttemptKind, AttemptReleaseReason, ProviderFence, RecordedRequestEvent, Reduction,
        RequestContext, RequestEvent, RequestState, reduce,
    },
    terminal::TerminalDisposition,
};
use darkbloom_coordinator_protocol::v2::{
    Abort, AttemptIdentity, BinaryFrameHeader, CoordinatorControlMessage, Digest, Prepare,
    Prepared, ProviderTerminal, Start, StartAck, StructuredError, TerminalOutcome,
};
use sha2::{Digest as ShaDigest, Sha256};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::provider::{
    DeliveryReceipt, DeliveryReceiptError, DeliveryState, ProviderWriterHandle, WriterEnqueueError,
};

use super::{
    byte_pipe::{
        BytePipeLimits, BytePipeReceiver, BytePipeSender, MAX_PIPE_BYTES, MAX_PIPE_ITEMS, PipeItem,
        RequestCancellation, ResponseLifetimeGuard, byte_pipe,
    },
    commit::{CommitmentLimits, OutputCommitment, OutputMode},
    error::{CancellationReason, PipeCloseReason, RequestExecutionError},
    output::{OutputExpectations, OutputLimits, OutputVerifier, VerifiedTerminal},
};

/// Immutable request task configuration.
#[derive(Clone, Debug)]
pub struct RequestTaskConfig {
    /// Pure-core request identity.
    pub request_id: CoreRequestId,
    /// Wire request identity.
    pub wire_request_id: darkbloom_coordinator_protocol::v2::RequestId,
    /// One immutable absolute deadline for every attempt.
    pub deadline: AbsoluteDeadline,
    /// Idempotent funding operation identity.
    pub funding_id: darkbloom_coordinator_core::ids::FundingId,
    /// Maximum amount reserved before provider capacity.
    pub funding_amount: MicroUsd,
    /// Exact canonical model.
    pub model: ModelId,
    /// Digest of the encrypted request body sent in Prepare.
    pub request_digest: Digest,
    /// Defensive upper bound for provider-tokenized input.
    pub maximum_prompt_tokens: u64,
    /// Streaming or one-body response behavior.
    pub output_mode: OutputMode,
    /// Strict authenticated output limits.
    pub output_limits: OutputLimits,
    /// Finite precommit/nonstreaming retention limits.
    pub commitment_limits: CommitmentLimits,
    /// Direct consumer-pipe limits.
    pub pipe_limits: BytePipeLimits,
}

/// Observable start-command delivery state.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DispatchState {
    /// Accepted into the sole provider writer's finite control lane.
    Queued,
    /// Send and flush completed.
    OnWire,
    /// Sending began but delivery cannot be determined.
    SentUnknown,
}

/// Tracks one start command without collapsing ambiguous delivery into failure.
#[derive(Clone, Debug)]
pub struct DispatchTracker {
    state: Option<DispatchState>,
    cancellation: RequestCancellation,
}

impl DispatchTracker {
    /// Creates an unqueued tracker under the already-installed cancellation.
    #[must_use]
    pub fn new(cancellation: RequestCancellation) -> Self {
        Self {
            state: None,
            cancellation,
        }
    }

    /// Records successful finite writer admission.
    pub fn mark_queued(&mut self) -> Result<(), RequestExecutionError> {
        if self.state.is_some() {
            return Err(RequestExecutionError::InvalidAttemptPhase);
        }
        self.state = Some(DispatchState::Queued);
        Ok(())
    }

    /// Records a terminal provider-writer receipt.
    pub fn observe(
        &mut self,
        state: DeliveryState,
    ) -> Result<DispatchState, RequestExecutionError> {
        match state {
            DeliveryState::Queued => {
                if self.state == Some(DispatchState::Queued) {
                    Ok(DispatchState::Queued)
                } else {
                    Err(RequestExecutionError::InvalidAttemptPhase)
                }
            }
            DeliveryState::OnWire => {
                if self.state != Some(DispatchState::Queued) {
                    return Err(RequestExecutionError::InvalidAttemptPhase);
                }
                self.state = Some(DispatchState::OnWire);
                Ok(DispatchState::OnWire)
            }
            DeliveryState::SentUnknown => {
                if self.state != Some(DispatchState::Queued) {
                    return Err(RequestExecutionError::InvalidAttemptPhase);
                }
                self.state = Some(DispatchState::SentUnknown);
                self.cancellation.cancel(CancellationReason::SentUnknown);
                Err(RequestExecutionError::SentUnknown)
            }
            DeliveryState::Failed(reason) => Err(RequestExecutionError::OutboundFailed(reason)),
        }
    }

    /// Returns the latest explicit delivery state.
    #[must_use]
    pub const fn state(&self) -> Option<DispatchState> {
        self.state
    }
}

/// Runtime phase of one strictly bounded attempt.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AttemptPhase {
    /// Prepare is accepted in the finite provider writer.
    PrepareQueued,
    /// Prepare is confirmed on wire.
    PrepareOnWire,
    /// Provider has returned validated prepared facts.
    Prepared,
    /// Start is accepted in the finite provider writer.
    StartQueued,
    /// Start is confirmed on wire.
    StartOnWire,
    /// Provider durably acknowledged start before emitting output.
    StartAcknowledged,
    /// Start delivery became ambiguous and cancellation fired.
    SentUnknown,
    /// Attempt safely ended before start authorization.
    Released,
    /// Selected attempt reached one terminal disposition.
    Terminal,
}

#[derive(Debug)]
struct RuntimeAttempt {
    identity: AttemptIdentity,
    provider: ProviderFence,
    request_digest: Digest,
    prepared: Option<Prepared>,
    phase: AttemptPhase,
    prepare_dispatch: DispatchTracker,
    start_dispatch: DispatchTracker,
    writer: ProviderWriterHandle,
}

/// Provider events that may arrive immediately after writer enqueue.
#[derive(Debug)]
pub enum InboundAttemptEvent {
    /// Complete prepare response.
    Prepared(Prepared),
    /// Durable start acknowledgement.
    StartAck(StartAck),
    /// Decrypted binary output, still carrying its authenticated header.
    Chunk {
        /// Strict fixed header.
        header: BinaryFrameHeader,
        /// Exact decrypted plaintext.
        plaintext: Vec<u8>,
    },
    /// Durable provider terminal.
    Terminal(ProviderTerminal),
    /// Structured failure associated with this exact attempt.
    StructuredError(StructuredError),
}

impl PipeItem for InboundAttemptEvent {
    fn pipe_bytes(&self) -> usize {
        match self {
            Self::Prepared(message) => 256_usize.saturating_add(message.model.len()),
            Self::StartAck(_) => 128,
            Self::Chunk { plaintext, .. } => 192_usize.saturating_add(plaintext.len()),
            Self::Terminal(message) => 512_usize
                .saturating_add(message.model.len())
                .saturating_add(message.signature.as_bytes().len()),
            Self::StructuredError(message) => {
                256_usize.saturating_add(message.message.as_ref().map_or(0, String::len))
            }
        }
    }
}

/// Creates the ordered event seam before any outbound enqueue.
///
/// A provider reader uses the returned sender's nonblocking `try_send`. Fast
/// Prepared → StartAck → chunk traffic is retained FIFO even when it all
/// arrives before the request task is next polled.
pub fn inbound_attempt_pipe(
    limits: BytePipeLimits,
    cancellation: RequestCancellation,
) -> Result<
    (
        BytePipeSender<InboundAttemptEvent>,
        BytePipeReceiver<InboundAttemptEvent>,
    ),
    super::error::PipeConfigError,
> {
    byte_pipe(limits, cancellation, None)
}

/// The sole mutable owner of one logical request aggregate.
///
/// Alternate and hedge attempts are entries in this object, never independent
/// request tasks. The core reducer is applied before output becomes visible.
#[derive(Debug)]
pub struct RequestTask {
    config: RequestTaskConfig,
    state: RequestState,
    event_sequence: u64,
    attempts: BTreeMap<CoreAttemptId, RuntimeAttempt>,
    authorized: Option<CoreAttemptId>,
    output: Option<OutputVerifier>,
    commitment: OutputCommitment,
    response: BytePipeSender<Vec<u8>>,
    cancellation: RequestCancellation,
}

impl RequestTask {
    /// Creates and funds one request, installing cancellation and the body
    /// lifetime guard before any outbound operation can occur.
    pub fn new(
        config: RequestTaskConfig,
        now: EpochMillis,
        cancellation: RequestCancellation,
        response_budget: Option<ResponseLifetimeGuard>,
    ) -> Result<(Self, BytePipeReceiver<Vec<u8>>), RequestExecutionError> {
        validate_config(&config)?;
        if config.deadline.is_expired_at(now) {
            cancellation.cancel(CancellationReason::DeadlineExpired);
            return Err(RequestExecutionError::DeadlineExpired);
        }
        let (response, receiver) =
            byte_pipe(config.pipe_limits, cancellation.clone(), response_budget).map_err(
                |error| RequestExecutionError::InvalidPrepared(error.to_string().into()),
            )?;
        let initial = RequestState::new(config.request_id, config.deadline);
        let mut task = Self {
            commitment: OutputCommitment::new(config.output_mode, config.commitment_limits),
            config,
            state: initial,
            event_sequence: 0,
            attempts: BTreeMap::new(),
            authorized: None,
            output: None,
            response,
            cancellation,
        };
        let context = RequestContext::new(now);
        task.apply(
            RequestEvent::FundsReserved {
                funding_id: task.config.funding_id,
                amount: task.config.funding_amount,
            },
            &context,
        )?;
        Ok((task, receiver))
    }

    /// Returns the immutable pure aggregate.
    #[must_use]
    pub const fn state(&self) -> &RequestState {
        &self.state
    }

    /// Returns the installed cancellation signal.
    #[must_use]
    pub const fn cancellation(&self) -> &RequestCancellation {
        &self.cancellation
    }

    /// Returns whether authenticated consumer-visible output selected the
    /// authorized attempt.
    #[must_use]
    pub const fn is_committed(&self) -> bool {
        self.commitment.is_committed()
    }

    /// Returns one runtime attempt phase.
    #[must_use]
    pub fn attempt_phase(&self, attempt_id: CoreAttemptId) -> Option<AttemptPhase> {
        self.attempts.get(&attempt_id).map(|attempt| attempt.phase)
    }

    /// Applies `AttemptPrepared` and synchronously enqueues the matching
    /// protocol Prepare under one transaction boundary.
    ///
    /// The ordered inbound event pipe must already be installed by the caller.
    /// Reducer validation is previewed before queue admission; neither state
    /// nor resource ownership changes when enqueue is definitely rejected.
    pub fn enqueue_prepare(
        &mut self,
        kind: AttemptKind,
        prepare: Prepare,
        provider: ProviderFence,
        permit_id: PermitId,
        context: &RequestContext,
        writer: &ProviderWriterHandle,
    ) -> Result<(CoreAttemptId, DeliveryReceipt), RequestExecutionError> {
        self.require_before_deadline(context.now())?;
        if self.cancellation.is_cancelled() {
            self.cancellation
                .cancel(CancellationReason::ClientCancelled);
            return Err(RequestExecutionError::Cancelled(
                CancellationReason::ClientCancelled,
            ));
        }
        validate_prepare(&self.config, kind, &prepare, &provider)?;
        let attempt_id = core_attempt_id(prepare.identity.attempt_id)?;
        let lease_id = core_lease_id(prepare.identity.lease_id)?;
        let event = RequestEvent::AttemptPrepared {
            attempt_id,
            kind,
            provider: provider.clone(),
            lease_id,
            permit_id,
        };
        let (reduction, next_sequence) = self.preview(event, context)?;
        let identity = prepare.identity.clone();
        let request_digest = prepare.request_digest;
        let receipt = writer
            .try_send_data_json(&CoordinatorControlMessage::Prepare(prepare))
            .map_err(map_enqueue_error)?;

        self.state = reduction.state;
        self.event_sequence = next_sequence;
        let mut prepare_dispatch = DispatchTracker::new(self.cancellation.clone());
        prepare_dispatch.mark_queued()?;
        self.attempts.insert(
            attempt_id,
            RuntimeAttempt {
                identity,
                provider,
                request_digest,
                prepared: None,
                phase: AttemptPhase::PrepareQueued,
                prepare_dispatch,
                start_dispatch: DispatchTracker::new(self.cancellation.clone()),
                writer: writer.clone(),
            },
        );
        Ok((attempt_id, receipt))
    }

    /// Awaits one finite Prepare receipt while cancellation remains selectable.
    pub async fn await_prepare_delivery(
        &mut self,
        attempt_id: CoreAttemptId,
        receipt: DeliveryReceipt,
        context: &RequestContext,
    ) -> Result<DispatchState, RequestExecutionError> {
        let token = self.cancellation.token();
        let delivery = tokio::select! {
            biased;
            () = token.cancelled() => {
                self.cancellation.cancel(CancellationReason::ClientCancelled);
                return Err(RequestExecutionError::Cancelled(
                    CancellationReason::ClientCancelled,
                ));
            }
            result = receipt.wait() => result.map_err(map_receipt_error)?,
        };
        self.observe_prepare_delivery(attempt_id, delivery, context)
    }

    /// Applies an already-observed Prepare writer result.
    pub fn observe_prepare_delivery(
        &mut self,
        attempt_id: CoreAttemptId,
        delivery: DeliveryState,
        context: &RequestContext,
    ) -> Result<DispatchState, RequestExecutionError> {
        if let DeliveryState::Failed(reason) = &delivery {
            let phase = self
                .attempts
                .get(&attempt_id)
                .ok_or(RequestExecutionError::UnknownAttempt)?
                .phase;
            if phase != AttemptPhase::PrepareQueued {
                return Err(RequestExecutionError::InvalidAttemptPhase);
            }
            self.apply(
                RequestEvent::AttemptReleased {
                    attempt_id,
                    reason: AttemptReleaseReason::PreAuthorizationFailure,
                },
                context,
            )?;
            self.attempts
                .get_mut(&attempt_id)
                .ok_or(RequestExecutionError::UnknownAttempt)?
                .phase = AttemptPhase::Released;
            return Err(RequestExecutionError::OutboundFailed(reason.clone()));
        }
        let attempt = self
            .attempts
            .get_mut(&attempt_id)
            .ok_or(RequestExecutionError::UnknownAttempt)?;
        let state = attempt.prepare_dispatch.observe(delivery);
        match state {
            Ok(DispatchState::OnWire) if attempt.phase == AttemptPhase::PrepareQueued => {
                attempt.phase = AttemptPhase::PrepareOnWire;
            }
            Err(RequestExecutionError::SentUnknown) => {
                attempt.phase = AttemptPhase::SentUnknown;
            }
            Ok(DispatchState::Queued | DispatchState::SentUnknown | DispatchState::OnWire)
            | Err(_) => {}
        }
        state
    }

    /// Validates the provider's complete prepared facts against the queued
    /// attempt. A fast response may legally precede observation of OnWire.
    pub fn accept_prepared(
        &mut self,
        prepared: Prepared,
    ) -> Result<CoreAttemptId, RequestExecutionError> {
        let attempt_id = core_attempt_id(prepared.identity.attempt_id)?;
        let attempt = self
            .attempts
            .get_mut(&attempt_id)
            .ok_or(RequestExecutionError::UnknownAttempt)?;
        if !matches!(
            attempt.phase,
            AttemptPhase::PrepareQueued | AttemptPhase::PrepareOnWire
        ) {
            return Err(RequestExecutionError::InvalidAttemptPhase);
        }
        if prepared.identity != attempt.identity {
            return Err(RequestExecutionError::IdentityMismatch);
        }
        validate_prepared(
            &self.config,
            &prepared,
            &attempt.provider,
            attempt.request_digest,
        )?;
        attempt.prepared = Some(prepared);
        attempt.phase = AttemptPhase::Prepared;
        Ok(attempt_id)
    }

    /// Safely releases a prepared primary/alternate before authorization.
    pub fn release_pre_authorization(
        &mut self,
        attempt_id: CoreAttemptId,
        context: &RequestContext,
    ) -> Result<DeliveryReceipt, RequestExecutionError> {
        let attempt = self
            .attempts
            .get(&attempt_id)
            .ok_or(RequestExecutionError::UnknownAttempt)?;
        if attempt.phase != AttemptPhase::Prepared {
            return Err(RequestExecutionError::InvalidAttemptPhase);
        }
        let identity = attempt.identity.clone();
        let writer = attempt.writer.clone();
        let (reduction, next_sequence) = self.preview(
            RequestEvent::AttemptReleased {
                attempt_id,
                reason: AttemptReleaseReason::PreAuthorizationFailure,
            },
            context,
        )?;
        let receipt = writer
            .try_send_control_json(&CoordinatorControlMessage::Abort(Abort {
                identity,
                reason: Some("pre-authorization attempt released".into()),
            }))
            .map_err(map_enqueue_error)?;
        self.state = reduction.state;
        self.event_sequence = next_sequence;
        self.attempts
            .get_mut(&attempt_id)
            .ok_or(RequestExecutionError::UnknownAttempt)?
            .phase = AttemptPhase::Released;
        Ok(receipt)
    }

    /// Records a definite provider failure before start authorization.
    ///
    /// This path performs no outbound write: a provider structured error or a
    /// definitely failed Prepare delivery already proves that generation
    /// cannot start from this attempt. The logical request may then consume
    /// its sole alternate.
    pub fn fail_pre_authorization(
        &mut self,
        attempt_id: CoreAttemptId,
        context: &RequestContext,
    ) -> Result<(), RequestExecutionError> {
        let attempt = self
            .attempts
            .get(&attempt_id)
            .ok_or(RequestExecutionError::UnknownAttempt)?;
        if !matches!(
            attempt.phase,
            AttemptPhase::PrepareQueued | AttemptPhase::PrepareOnWire | AttemptPhase::Prepared
        ) || self.authorized.is_some()
        {
            return Err(RequestExecutionError::InvalidAttemptPhase);
        }
        self.apply(
            RequestEvent::AttemptReleased {
                attempt_id,
                reason: AttemptReleaseReason::PreAuthorizationFailure,
            },
            context,
        )?;
        self.attempts
            .get_mut(&attempt_id)
            .ok_or(RequestExecutionError::UnknownAttempt)?
            .phase = AttemptPhase::Released;
        Ok(())
    }

    /// Atomically selects one attempt and synchronously enqueues Start.
    ///
    /// The reducer transition is previewed first. Queue admission performs no
    /// await. Only after admission succeeds is the transition committed and
    /// the state exposed as [`DispatchState::Queued`]. Thus no caller can
    /// accidentally treat an ambiguous send as a safe failover.
    pub fn enqueue_start(
        &mut self,
        attempt_id: CoreAttemptId,
        context: &RequestContext,
    ) -> Result<DeliveryReceipt, RequestExecutionError> {
        self.require_before_deadline(context.now())?;
        if self.cancellation.is_cancelled() {
            self.cancellation
                .cancel(CancellationReason::ClientCancelled);
            return Err(RequestExecutionError::Cancelled(
                CancellationReason::ClientCancelled,
            ));
        }
        let attempt = self
            .attempts
            .get(&attempt_id)
            .ok_or(RequestExecutionError::UnknownAttempt)?;
        if attempt.phase != AttemptPhase::Prepared {
            return Err(RequestExecutionError::InvalidAttemptPhase);
        }
        let payload = RequestEvent::StartAuthorized {
            attempt_id,
            provider: attempt.provider.clone(),
        };
        let (reduction, next_sequence) = self.preview(payload, context)?;
        let start = CoordinatorControlMessage::Start(Start {
            identity: attempt.identity.clone(),
        });
        let receipt = attempt
            .writer
            .try_send_control_json(&start)
            .map_err(map_enqueue_error)?;

        self.state = reduction.state;
        self.event_sequence = next_sequence;
        self.authorized = Some(attempt_id);
        let mut losing_attempts = Vec::new();
        for (other_id, runtime) in &mut self.attempts {
            if *other_id != attempt_id
                && matches!(
                    runtime.phase,
                    AttemptPhase::PrepareQueued
                        | AttemptPhase::PrepareOnWire
                        | AttemptPhase::Prepared
                )
            {
                runtime.phase = AttemptPhase::Released;
                losing_attempts.push((runtime.writer.clone(), runtime.identity.clone()));
            }
        }
        let attempt = self
            .attempts
            .get_mut(&attempt_id)
            .ok_or(RequestExecutionError::UnknownAttempt)?;
        attempt.start_dispatch.mark_queued()?;
        attempt.phase = AttemptPhase::StartQueued;
        let prepared = attempt
            .prepared
            .as_ref()
            .ok_or(RequestExecutionError::InvalidAttemptPhase)?;
        self.output = Some(OutputVerifier::new(OutputExpectations {
            identity: attempt.identity.clone(),
            model: prepared.model.clone(),
            prompt_tokens: prepared.prompt_tokens,
            limits: self.config.output_limits,
        }));
        for (loser_writer, identity) in losing_attempts {
            if let Err(error) =
                loser_writer.try_send_control_json(&CoordinatorControlMessage::Abort(Abort {
                    identity,
                    reason: Some("not selected for start authorization".into()),
                }))
            {
                self.cancellation.cancel(CancellationReason::RequestEnded);
                return Err(map_enqueue_error(error));
            }
        }
        Ok(receipt)
    }

    /// Awaits one finite start receipt while cancellation remains selectable.
    ///
    /// The cancellation token was installed by [`Self::new`] before the writer
    /// enqueue and therefore before this first outbound await.
    pub async fn await_start_delivery(
        &mut self,
        attempt_id: CoreAttemptId,
        receipt: DeliveryReceipt,
    ) -> Result<DispatchState, RequestExecutionError> {
        let token = self.cancellation.token();
        let delivery = tokio::select! {
            biased;
            () = token.cancelled() => {
                self.cancellation.cancel(CancellationReason::ClientCancelled);
                return Err(RequestExecutionError::Cancelled(
                    CancellationReason::ClientCancelled,
                ));
            }
            result = receipt.wait() => result.map_err(map_receipt_error)?,
        };
        self.observe_start_delivery(attempt_id, delivery)
    }

    /// Applies an already-observed writer delivery result.
    pub fn observe_start_delivery(
        &mut self,
        attempt_id: CoreAttemptId,
        delivery: DeliveryState,
    ) -> Result<DispatchState, RequestExecutionError> {
        let attempt = self
            .attempts
            .get_mut(&attempt_id)
            .ok_or(RequestExecutionError::UnknownAttempt)?;
        let state = attempt.start_dispatch.observe(delivery);
        match state {
            Ok(DispatchState::OnWire) if attempt.phase == AttemptPhase::StartQueued => {
                attempt.phase = AttemptPhase::StartOnWire;
            }
            Err(RequestExecutionError::SentUnknown) => {
                attempt.phase = AttemptPhase::SentUnknown;
            }
            Ok(DispatchState::Queued | DispatchState::SentUnknown | DispatchState::OnWire)
            | Err(_) => {}
        }
        state
    }

    /// Accepts the durable StartAck that must precede every output frame.
    pub fn accept_start_ack(&mut self, ack: &StartAck) -> Result<(), RequestExecutionError> {
        let attempt_id = self
            .authorized
            .ok_or(RequestExecutionError::InvalidAttemptPhase)?;
        let attempt = self
            .attempts
            .get_mut(&attempt_id)
            .ok_or(RequestExecutionError::UnknownAttempt)?;
        if ack.identity != attempt.identity {
            return Err(RequestExecutionError::IdentityMismatch);
        }
        if !matches!(
            attempt.phase,
            AttemptPhase::StartQueued | AttemptPhase::StartOnWire
        ) {
            return Err(RequestExecutionError::InvalidAttemptPhase);
        }
        attempt.phase = AttemptPhase::StartAcknowledged;
        Ok(())
    }

    /// Validates and directly relays one output frame without spawning.
    pub fn accept_chunk(
        &mut self,
        header: &BinaryFrameHeader,
        plaintext: Vec<u8>,
        context: &RequestContext,
    ) -> Result<(), RequestExecutionError> {
        self.require_before_deadline(context.now())?;
        let attempt_id = self
            .authorized
            .ok_or(RequestExecutionError::InvalidAttemptPhase)?;
        let attempt = self
            .attempts
            .get(&attempt_id)
            .ok_or(RequestExecutionError::UnknownAttempt)?;
        if attempt.phase != AttemptPhase::StartAcknowledged {
            self.cancellation
                .cancel(CancellationReason::ProtocolViolation);
            return Err(RequestExecutionError::InvalidAttemptPhase);
        }

        let verified = self
            .output
            .as_mut()
            .ok_or(RequestExecutionError::InvalidAttemptPhase)?
            .accept(header, plaintext)
            .inspect_err(|_| {
                self.cancellation
                    .cancel(CancellationReason::ProtocolViolation);
            })?;
        let first_content_reduction = if verified.class == super::commit::ChunkClass::Content
            && !self.state.has_first_content()
        {
            let provider = attempt.provider.clone();
            Some(
                self.preview(
                    RequestEvent::FirstContent {
                        attempt_id,
                        provider,
                    },
                    context,
                )
                .inspect_err(|_| {
                    self.cancellation
                        .cancel(CancellationReason::ProtocolViolation);
                })?,
            )
        } else {
            None
        };
        let output = self
            .commitment
            .accept(verified.class, verified.bytes)
            .inspect_err(|_| {
                self.cancellation
                    .cancel(CancellationReason::ProtocolViolation);
            })?;
        if let Some((reduction, next_sequence)) = first_content_reduction {
            debug_assert!(output.first_content);
            self.state = reduction.state;
            self.event_sequence = next_sequence;
        }
        for item in output.ready {
            self.response.try_send(item)?;
        }
        Ok(())
    }

    /// Validates one provider terminal, applies the sole accounting
    /// disposition, and gracefully completes successful response output.
    pub fn accept_terminal<F>(
        &mut self,
        terminal: &ProviderTerminal,
        disposition: TerminalDisposition,
        context: &RequestContext,
        verify_signature: F,
    ) -> Result<VerifiedTerminal, RequestExecutionError>
    where
        F: FnOnce(
            darkbloom_coordinator_protocol::v2::ProviderId,
            darkbloom_coordinator_protocol::v2::ProviderProcessGenerationId,
            &Digest,
            &[u8],
        ) -> bool,
    {
        let attempt_id = self
            .authorized
            .ok_or(RequestExecutionError::InvalidAttemptPhase)?;
        let attempt = self
            .attempts
            .get(&attempt_id)
            .ok_or(RequestExecutionError::UnknownAttempt)?;
        if terminal.identity != attempt.identity {
            return Err(RequestExecutionError::IdentityMismatch);
        }
        if !matches!(
            attempt.phase,
            AttemptPhase::StartAcknowledged | AttemptPhase::SentUnknown
        ) {
            return Err(RequestExecutionError::InvalidAttemptPhase);
        }
        let (reduction, next_sequence) =
            self.preview(RequestEvent::Terminated { disposition }, context)?;
        let summary = self
            .output
            .as_mut()
            .ok_or(RequestExecutionError::InvalidAttemptPhase)?
            .validate_terminal(terminal, verify_signature)
            .inspect_err(|_| {
                self.cancellation
                    .cancel(CancellationReason::ProtocolViolation);
            })?;
        let ready = if terminal.outcome == TerminalOutcome::Completed {
            self.commitment.finish_success()?
        } else {
            Vec::new()
        };
        self.state = reduction.state;
        self.event_sequence = next_sequence;
        self.attempts
            .get_mut(&attempt_id)
            .ok_or(RequestExecutionError::UnknownAttempt)?
            .phase = AttemptPhase::Terminal;
        self.cancellation.complete();
        for item in ready {
            self.response.try_send(item)?;
        }
        if terminal.outcome == TerminalOutcome::Completed {
            self.response.finish();
        } else {
            self.response.close(PipeCloseReason::ProviderFailed);
        }
        Ok(summary)
    }

    /// Cancels this logical job and releases all reducer-owned resources once.
    pub fn cancel(
        &mut self,
        reason: CancellationReason,
        context: &RequestContext,
    ) -> Result<(), RequestExecutionError> {
        if self.state.is_terminal() {
            return Ok(());
        }
        self.cancellation.cancel(reason);
        self.apply(
            RequestEvent::Terminated {
                disposition: TerminalDisposition::Released,
            },
            context,
        )?;
        for (attempt_id, runtime) in &mut self.attempts {
            runtime.phase = if self.authorized == Some(*attempt_id) {
                AttemptPhase::Terminal
            } else {
                AttemptPhase::Released
            };
        }
        self.response.close(match reason {
            CancellationReason::DeadlineExpired => PipeCloseReason::DeadlineExpired,
            CancellationReason::ProtocolViolation => PipeCloseReason::ProtocolViolation,
            CancellationReason::ClientCancelled
            | CancellationReason::ConsumerDropped
            | CancellationReason::SlowConsumer
            | CancellationReason::SentUnknown
            | CancellationReason::RequestEnded => PipeCloseReason::Cancelled,
        });
        Ok(())
    }

    fn require_before_deadline(&self, now: EpochMillis) -> Result<(), RequestExecutionError> {
        if self.config.deadline.is_expired_at(now) {
            self.cancellation
                .cancel(CancellationReason::DeadlineExpired);
            Err(RequestExecutionError::DeadlineExpired)
        } else {
            Ok(())
        }
    }

    fn apply(
        &mut self,
        payload: RequestEvent,
        context: &RequestContext,
    ) -> Result<(), RequestExecutionError> {
        let (reduction, next_sequence) = self.preview(payload, context)?;
        self.state = reduction.state;
        self.event_sequence = next_sequence;
        Ok(())
    }

    fn preview(
        &self,
        payload: RequestEvent,
        context: &RequestContext,
    ) -> Result<(Reduction, u64), RequestExecutionError> {
        let next_sequence = self.event_sequence.checked_add(1).ok_or_else(|| {
            RequestExecutionError::EventEncoding(Arc::from("request event sequence overflow"))
        })?;
        let payload_bytes = serde_json::to_vec(&payload)
            .map_err(|error| RequestExecutionError::EventEncoding(error.to_string().into()))?;
        let digest_bytes: [u8; 32] = Sha256::digest(&payload_bytes).into();
        let digest = CoreDigest::new(digest_bytes);
        let mut event_hasher = Sha256::new();
        event_hasher.update(self.config.request_id.as_uuid().as_bytes());
        event_hasher.update(next_sequence.to_be_bytes());
        event_hasher.update(digest_bytes);
        let event_hash: [u8; 32] = event_hasher.finalize().into();
        let mut event_uuid = [0_u8; 16];
        event_uuid.copy_from_slice(&event_hash[..16]);
        if event_uuid == [0; 16] {
            event_uuid[15] = 1;
        }
        let event_id = EventId::new(Uuid::from_bytes(event_uuid))
            .map_err(|error| RequestExecutionError::EventEncoding(error.to_string().into()))?;
        let event = RecordedRequestEvent {
            id: event_id,
            digest,
            payload,
        };
        let reduction = reduce(&self.state, &event, context)?;
        Ok((reduction, next_sequence))
    }
}

impl Drop for RequestTask {
    fn drop(&mut self) {
        if !self.state.is_terminal() {
            self.cancellation.cancel(CancellationReason::RequestEnded);
        }
    }
}

fn validate_config(config: &RequestTaskConfig) -> Result<(), RequestExecutionError> {
    if config.request_id.as_uuid().as_bytes() != config.wire_request_id.as_bytes() {
        return Err(RequestExecutionError::InvalidPrepared(
            "core and wire request identities differ".into(),
        ));
    }
    if config.maximum_prompt_tokens == 0
        || config.output_limits.maximum_chunk_bytes == 0
        || config.output_limits.maximum_output_bytes == 0
        || config.output_limits.maximum_chunks == 0
        || config.output_limits.maximum_output_tokens == 0
        || config.commitment_limits.maximum_items == 0
        || config.commitment_limits.maximum_bytes == 0
    {
        return Err(RequestExecutionError::InvalidPrepared(
            "request execution limits must be nonzero".into(),
        ));
    }
    if config.output_limits.maximum_chunk_bytes
        > darkbloom_coordinator_protocol::MAX_V2_CIPHERTEXT_LEN
        || config.output_limits.maximum_output_bytes > MAX_PIPE_BYTES
        || config.output_limits.maximum_chunks > MAX_PIPE_ITEMS
        || config.commitment_limits.maximum_bytes > MAX_PIPE_BYTES
        || config.commitment_limits.maximum_items > MAX_PIPE_ITEMS
    {
        return Err(RequestExecutionError::InvalidPrepared(
            "request execution limits exceed process hard bounds".into(),
        ));
    }
    if config.output_mode == OutputMode::NonStreaming
        && (config.commitment_limits.maximum_bytes < config.output_limits.maximum_output_bytes
            || config.pipe_limits.maximum_bytes < config.output_limits.maximum_output_bytes)
    {
        return Err(RequestExecutionError::InvalidPrepared(
            "nonstreaming retention and pipe bounds must cover maximum output".into(),
        ));
    }
    Ok(())
}

fn validate_prepare(
    config: &RequestTaskConfig,
    kind: AttemptKind,
    prepare: &Prepare,
    provider: &ProviderFence,
) -> Result<(), RequestExecutionError> {
    if prepare.identity.request_id != config.wire_request_id
        || prepare.identity.provider_id.as_bytes() != provider.provider_id.as_uuid().as_bytes()
    {
        return Err(RequestExecutionError::IdentityMismatch);
    }
    if prepare.model != config.model.as_str() || provider.model_id != config.model {
        return Err(RequestExecutionError::InvalidPrepared(
            "prepare model or request digest mismatch".into(),
        ));
    }
    if kind == AttemptKind::Primary && prepare.request_digest != config.request_digest {
        return Err(RequestExecutionError::InvalidPrepared(
            "primary prepare request digest mismatch".into(),
        ));
    }
    let payload_digest = Prepare::encrypted_payload_digest(&prepare.encrypted_body)
        .map_err(|error| RequestExecutionError::InvalidPrepared(error.to_string().into()))?;
    if payload_digest != prepare.request_digest {
        return Err(RequestExecutionError::InvalidPrepared(
            "prepare digest does not cover the encrypted payload".into(),
        ));
    }
    Ok(())
}

fn validate_prepared(
    config: &RequestTaskConfig,
    prepared: &Prepared,
    provider: &ProviderFence,
    request_digest: Digest,
) -> Result<(), RequestExecutionError> {
    if prepared.identity.request_id != config.wire_request_id {
        return Err(RequestExecutionError::IdentityMismatch);
    }
    if prepared.identity.provider_id.as_bytes() != provider.provider_id.as_uuid().as_bytes() {
        return Err(RequestExecutionError::IdentityMismatch);
    }
    if prepared.model != config.model.as_str()
        || provider.model_id != config.model
        || prepared.request_digest != request_digest
    {
        return Err(RequestExecutionError::InvalidPrepared(
            "model or request digest mismatch".into(),
        ));
    }
    if prepared.lease_ttl_ms == 0
        || prepared.prompt_tokens > config.maximum_prompt_tokens
        || prepared.max_output_tokens != config.output_limits.maximum_output_tokens
    {
        return Err(RequestExecutionError::InvalidPrepared(
            "lease TTL or token bounds are invalid".into(),
        ));
    }
    Ok(())
}

fn core_attempt_id(
    value: darkbloom_coordinator_protocol::v2::AttemptId,
) -> Result<CoreAttemptId, RequestExecutionError> {
    CoreAttemptId::new(Uuid::from_bytes(value.into_bytes()))
        .map_err(|error| RequestExecutionError::InvalidPrepared(error.to_string().into()))
}

fn core_lease_id(
    value: darkbloom_coordinator_protocol::v2::LeaseId,
) -> Result<CoreLeaseId, RequestExecutionError> {
    CoreLeaseId::new(Uuid::from_bytes(value.into_bytes()))
        .map_err(|error| RequestExecutionError::InvalidPrepared(error.to_string().into()))
}

fn map_enqueue_error(error: WriterEnqueueError) -> RequestExecutionError {
    RequestExecutionError::OutboundRejected(error.to_string().into())
}

fn map_receipt_error(error: DeliveryReceiptError) -> RequestExecutionError {
    RequestExecutionError::DeliveryReceipt(error.to_string().into())
}

/// Convenience cancellation setup for callers without a custom token.
#[must_use]
pub fn request_cancellation(
    callback: impl Fn(CancellationReason) + Send + Sync + 'static,
) -> RequestCancellation {
    RequestCancellation::new(CancellationToken::new(), callback)
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use base64::{Engine, engine::general_purpose::STANDARD};
    use darkbloom_coordinator_core::ids::{
        FundingId, ModelRevision, ProviderId as CoreProviderId, SessionId, SessionRevision,
        TrustRevision,
    };
    use darkbloom_coordinator_protocol::v2::{
        AttemptId, LeaseId, ProviderId, ProviderProcessGenerationId, RequestId, ReservationId,
        SessionEpoch, TerminalSignature,
    };

    use super::*;
    use crate::provider::{ProviderWriterConfig, provider_writer};

    fn identity() -> AttemptIdentity {
        AttemptIdentity {
            provider_id: ProviderId::new([1; 16]),
            provider_process_generation: ProviderProcessGenerationId::new([2; 16]),
            session_epoch: SessionEpoch(3),
            request_id: RequestId::new([4; 16]),
            attempt_id: AttemptId::new([5; 16]),
            reservation_id: ReservationId::new([6; 16]),
            lease_id: LeaseId::new([7; 16]),
        }
    }

    #[test]
    fn sent_unknown_is_distinct_and_cancels_exactly_once() {
        let count = Arc::new(AtomicUsize::new(0));
        let observed = count.clone();
        let cancellation = request_cancellation(move |_| {
            observed.fetch_add(1, Ordering::AcqRel);
        });
        let mut tracker = DispatchTracker::new(cancellation.clone());
        tracker.mark_queued().expect("queued");
        assert!(matches!(
            tracker.observe(DeliveryState::SentUnknown),
            Err(RequestExecutionError::SentUnknown)
        ));
        assert_eq!(tracker.state(), Some(DispatchState::SentUnknown));
        cancellation.cancel(CancellationReason::ClientCancelled);
        assert_eq!(count.load(Ordering::Acquire), 1);
    }

    #[tokio::test]
    async fn preinstalled_inbox_preserves_fast_prepare_ack_chunk_order() {
        let cancellation = RequestCancellation::token_only(CancellationToken::new());
        let (sender, mut receiver) = inbound_attempt_pipe(
            BytePipeLimits {
                maximum_items: 4,
                maximum_bytes: 4096,
            },
            cancellation,
        )
        .expect("inbox");
        let expected = identity();
        let prepared = Prepared {
            identity: expected.clone(),
            model: "m".into(),
            request_digest: Digest::new([8; 32]),
            lease_ttl_ms: 100,
            prompt_tokens: 1,
            max_output_tokens: 1,
            engine_queue_depth: 0,
            reserved_kv_bytes: 1,
            reserved_media_bytes: 0,
            prefill_can_begin: true,
            estimated_prefill_ms: None,
        };
        let ack = StartAck {
            identity: expected.clone(),
        };
        let header = BinaryFrameHeader {
            kind: darkbloom_coordinator_protocol::v2::BinaryFrameKind::ResponseChunk,
            flags: darkbloom_coordinator_protocol::v2::BinaryFrameFlags::EMPTY,
            minor: 1,
            provider_id: expected.provider_id,
            provider_process_generation: expected.provider_process_generation,
            session_epoch: expected.session_epoch,
            request_id: expected.request_id,
            attempt_id: expected.attempt_id,
            reservation_id: expected.reservation_id,
            lease_id: expected.lease_id,
            nonce: [0; 24],
            rolling_digest: [0; 32],
            sequence: 0,
            ciphertext_len: 1,
            cumulative_tokens: 1,
        };

        sender
            .try_send(InboundAttemptEvent::Prepared(prepared))
            .expect("prepared");
        sender
            .try_send(InboundAttemptEvent::StartAck(ack))
            .expect("ack");
        sender
            .try_send(InboundAttemptEvent::Chunk {
                header,
                plaintext: vec![1],
            })
            .expect("chunk");

        assert!(matches!(
            receiver.recv().await.expect("event"),
            Some(InboundAttemptEvent::Prepared(_))
        ));
        assert!(matches!(
            receiver.recv().await.expect("event"),
            Some(InboundAttemptEvent::StartAck(_))
        ));
        assert!(matches!(
            receiver.recv().await.expect("event"),
            Some(InboundAttemptEvent::Chunk { .. })
        ));
        sender.finish();
    }

    fn core_id<T, E: std::fmt::Debug>(byte: u8, create: impl FnOnce(Uuid) -> Result<T, E>) -> T {
        create(Uuid::from_bytes([byte; 16])).expect("core identifier")
    }

    fn fence(provider: u8) -> ProviderFence {
        ProviderFence {
            provider_id: core_id(provider, CoreProviderId::new),
            session_id: core_id(provider.saturating_add(20), SessionId::new),
            session_revision: SessionRevision::new(1).expect("session revision"),
            trust_revision: TrustRevision::new(1).expect("trust revision"),
            model_id: ModelId::new("model").expect("model"),
            model_revision: ModelRevision::new(1).expect("model revision"),
        }
    }

    fn wire_identity(provider: u8, attempt: u8, lease: u8) -> AttemptIdentity {
        AttemptIdentity {
            provider_id: ProviderId::new([provider; 16]),
            provider_process_generation: ProviderProcessGenerationId::new(
                [provider.saturating_add(10); 16],
            ),
            session_epoch: SessionEpoch(1),
            request_id: RequestId::new([4; 16]),
            attempt_id: AttemptId::new([attempt; 16]),
            reservation_id: ReservationId::new([attempt.saturating_add(20); 16]),
            lease_id: LeaseId::new([lease; 16]),
        }
    }

    fn prepare(identity: AttemptIdentity) -> Prepare {
        let encrypted_body = darkbloom_coordinator_protocol::v1::EncryptedPayload {
            ephemeral_public_key: STANDARD.encode([1; 32]),
            ciphertext: STANDARD.encode([2; 32]),
        };
        let request_digest =
            Prepare::encrypted_payload_digest(&encrypted_body).expect("payload digest");
        Prepare {
            identity,
            model: "model".into(),
            request_digest,
            encrypted_body,
        }
    }

    fn prepared(prepare: &Prepare) -> Prepared {
        Prepared {
            identity: prepare.identity.clone(),
            model: prepare.model.clone(),
            request_digest: prepare.request_digest,
            lease_ttl_ms: 1_000,
            prompt_tokens: 2,
            max_output_tokens: 8,
            engine_queue_depth: 0,
            reserved_kv_bytes: 1,
            reserved_media_bytes: 0,
            prefill_can_begin: true,
            estimated_prefill_ms: Some(1),
        }
    }

    fn task_config(request_digest: Digest) -> RequestTaskConfig {
        RequestTaskConfig {
            request_id: core_id(4, CoreRequestId::new),
            wire_request_id: RequestId::new([4; 16]),
            deadline: AbsoluteDeadline::new(10_000).expect("deadline"),
            funding_id: core_id(9, FundingId::new),
            funding_amount: MicroUsd::new(100),
            model: ModelId::new("model").expect("model"),
            request_digest,
            maximum_prompt_tokens: 32,
            output_mode: OutputMode::Streaming,
            output_limits: OutputLimits {
                maximum_chunk_bytes: 1024,
                maximum_output_bytes: 4096,
                maximum_chunks: 32,
                maximum_output_tokens: 8,
            },
            commitment_limits: CommitmentLimits {
                maximum_items: 8,
                maximum_bytes: 2048,
            },
            pipe_limits: BytePipeLimits {
                maximum_items: 8,
                maximum_bytes: 4096,
            },
        }
    }

    #[test]
    fn definite_prepare_failure_allows_exactly_one_alternate() {
        let primary_prepare = prepare(wire_identity(1, 5, 7));
        let alternate_prepare = prepare(wire_identity(2, 6, 8));
        let second_alternate = prepare(wire_identity(3, 7, 9));
        let (mut task, _body) = RequestTask::new(
            task_config(primary_prepare.request_digest),
            EpochMillis::new(1),
            RequestCancellation::token_only(CancellationToken::new()),
            None,
        )
        .expect("task");
        let primary_fence = fence(1);
        let alternate_fence = fence(2);
        let second_alternate_fence = fence(3);
        let context = RequestContext::new(EpochMillis::new(2))
            .with_provider(primary_fence.clone())
            .with_provider(alternate_fence.clone())
            .with_provider(second_alternate_fence.clone());
        let (_writer, handle) =
            provider_writer(ProviderWriterConfig::default(), CancellationToken::new())
                .expect("writer");
        let (primary_id, _receipt) = task
            .enqueue_prepare(
                AttemptKind::Primary,
                primary_prepare,
                primary_fence,
                core_id(11, PermitId::new),
                &context,
                &handle,
            )
            .expect("primary");
        assert!(matches!(
            task.observe_prepare_delivery(
                primary_id,
                DeliveryState::Failed("definite queue failure".into()),
                &context,
            ),
            Err(RequestExecutionError::OutboundFailed(_))
        ));
        assert_eq!(task.attempt_phase(primary_id), Some(AttemptPhase::Released));

        task.enqueue_prepare(
            AttemptKind::Alternate,
            alternate_prepare,
            alternate_fence,
            core_id(12, PermitId::new),
            &context,
            &handle,
        )
        .expect("sole alternate");
        assert!(matches!(
            task.enqueue_prepare(
                AttemptKind::Alternate,
                second_alternate,
                second_alternate_fence,
                core_id(13, PermitId::new),
                &context,
                &handle,
            ),
            Err(RequestExecutionError::Reducer(
                darkbloom_coordinator_core::request::RequestError::AlternateAlreadyPrepared
            ))
        ));
        assert_eq!(
            task.state()
                .resources()
                .active_leases()
                .expect("resource accounting"),
            1
        );
    }

    #[tokio::test]
    async fn one_job_bounds_hedge_and_preserves_fast_start_output_order() {
        let primary_prepare = prepare(wire_identity(1, 5, 7));
        let hedge_prepare = prepare(wire_identity(2, 6, 8));
        let second_hedge_prepare = prepare(wire_identity(3, 7, 9));
        let cancellation = RequestCancellation::token_only(CancellationToken::new());
        let (mut task, mut body) = RequestTask::new(
            task_config(primary_prepare.request_digest),
            EpochMillis::new(1),
            cancellation,
            None,
        )
        .expect("task");
        let primary_fence = fence(1);
        let hedge_fence = fence(2);
        let second_hedge_fence = fence(3);
        let context = RequestContext::new(EpochMillis::new(2))
            .with_provider(primary_fence.clone())
            .with_provider(hedge_fence.clone())
            .with_provider(second_hedge_fence.clone());
        let (_writer, handle) =
            provider_writer(ProviderWriterConfig::default(), CancellationToken::new())
                .expect("writer");

        let (primary_id, _receipt) = task
            .enqueue_prepare(
                AttemptKind::Primary,
                primary_prepare.clone(),
                primary_fence,
                core_id(11, PermitId::new),
                &context,
                &handle,
            )
            .expect("primary prepare");
        task.accept_prepared(prepared(&primary_prepare))
            .expect("primary prepared");
        let (hedge_id, _receipt) = task
            .enqueue_prepare(
                AttemptKind::Hedge,
                hedge_prepare.clone(),
                hedge_fence,
                core_id(12, PermitId::new),
                &context,
                &handle,
            )
            .expect("hedge prepare");
        task.accept_prepared(prepared(&hedge_prepare))
            .expect("hedge prepared");

        assert!(matches!(
            task.enqueue_prepare(
                AttemptKind::Hedge,
                second_hedge_prepare,
                second_hedge_fence,
                core_id(13, PermitId::new),
                &context,
                &handle,
            ),
            Err(RequestExecutionError::Reducer(
                darkbloom_coordinator_core::request::RequestError::HedgeAlreadyPrepared
            ))
        ));

        let _start = task
            .enqueue_start(primary_id, &context)
            .expect("start queued");
        assert_eq!(
            task.attempt_phase(primary_id),
            Some(AttemptPhase::StartQueued)
        );
        assert_eq!(task.attempt_phase(hedge_id), Some(AttemptPhase::Released));
        assert!(matches!(
            task.release_pre_authorization(primary_id, &context),
            Err(RequestExecutionError::InvalidAttemptPhase)
        ));
        assert_eq!(task.state().authorized_attempt(), Some(primary_id));

        task.accept_start_ack(&StartAck {
            identity: primary_prepare.identity.clone(),
        })
        .expect("fast start ack");
        task.observe_start_delivery(primary_id, DeliveryState::OnWire)
            .expect("late wire receipt");
        assert_eq!(
            task.attempt_phase(primary_id),
            Some(AttemptPhase::StartAcknowledged)
        );

        let content = b"data: {\"content\":\"hello\"}\n\n";
        let done = b"data: [DONE]\n\n";
        let first_digest = crate::request::next_rolling_digest([0; 32], 0, 1, content);
        let first = output_header(
            &primary_prepare.identity,
            0,
            1,
            first_digest,
            content.len(),
            false,
        );
        task.accept_chunk(&first, content.to_vec(), &context)
            .expect("content");
        let done_digest = crate::request::next_rolling_digest(first_digest, 1, 1, done);
        let final_frame = output_header(
            &primary_prepare.identity,
            1,
            1,
            done_digest,
            done.len(),
            true,
        );
        task.accept_chunk(&final_frame, done.to_vec(), &context)
            .expect("done");

        let exact = [content.as_slice(), done.as_slice()].concat();
        let mut terminal = ProviderTerminal {
            identity: primary_prepare.identity.clone(),
            outcome: TerminalOutcome::Completed,
            error_class: None,
            prompt_tokens: 2,
            completion_tokens: 1,
            reasoning_tokens: 0,
            response_hash: Digest::of(&exact),
            final_generated_tokens: 1,
            rolling_digest: Digest::new(done_digest),
            model: "model".into(),
            terminal_digest: Digest::default(),
            signature: TerminalSignature::new(vec![1]),
        };
        terminal.terminal_digest = terminal.computed_digest().expect("terminal digest");
        task.accept_terminal(
            &terminal,
            TerminalDisposition::Released,
            &context,
            |_, _, _, _| true,
        )
        .expect("terminal");
        assert_eq!(
            body.recv().await.expect("content body"),
            Some(content.to_vec())
        );
        assert_eq!(body.recv().await.expect("done body"), Some(done.to_vec()));
        assert_eq!(body.recv().await.expect("EOF"), None);
    }

    fn output_header(
        identity: &AttemptIdentity,
        sequence: u64,
        cumulative_tokens: u64,
        rolling_digest: [u8; 32],
        plaintext_len: usize,
        final_frame: bool,
    ) -> BinaryFrameHeader {
        BinaryFrameHeader {
            kind: darkbloom_coordinator_protocol::v2::BinaryFrameKind::ResponseChunk,
            flags: if final_frame {
                darkbloom_coordinator_protocol::v2::BinaryFrameFlags::FINAL
            } else {
                darkbloom_coordinator_protocol::v2::BinaryFrameFlags::EMPTY
            },
            minor: 1,
            provider_id: identity.provider_id,
            provider_process_generation: identity.provider_process_generation,
            session_epoch: identity.session_epoch,
            request_id: identity.request_id,
            attempt_id: identity.attempt_id,
            reservation_id: identity.reservation_id,
            lease_id: identity.lease_id,
            nonce: [0; 24],
            rolling_digest,
            sequence,
            ciphertext_len: u32::try_from(plaintext_len).expect("bounded"),
            cumulative_tokens,
        }
    }
}
