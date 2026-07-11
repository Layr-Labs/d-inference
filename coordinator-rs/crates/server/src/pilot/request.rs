use std::{
    sync::{Arc, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use darkbloom_coordinator_core::{
    deadline::{AbsoluteDeadline, EpochMillis},
    fleet::{AdmissionDemand, AdmissionKind},
    ids::{FundingId, ModelId, RequestId as CoreRequestId},
    money::MicroUsd,
    request::{AttemptKind, ProviderFence, RequestContext},
    terminal::TerminalDisposition as CoreTerminalDisposition,
    tokens::{KvBytes, TokenCount},
    traits::{Capability, RequestTraits},
};
use darkbloom_coordinator_protocol::v2::{
    Abort, AttemptId, AttemptIdentity, Cancel, CoordinatorControlMessage, LeaseId, Prepare,
    ProviderTerminal, RequestId, ReservationId, StructuredErrorClass, TerminalAck,
    TerminalDisposition, TerminalOutcome,
};
use serde_json::Value;
use thiserror::Error;
use tokio::{
    sync::{OwnedSemaphorePermit, Semaphore, mpsc, oneshot},
    task::JoinSet,
    time::{MissedTickBehavior, interval_at},
};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::{
    crypto::{
        DurableIoPool, TerminalKey, TerminalRecord, TerminalResolution, seal_request_for_provider,
    },
    fleet::{
        AdmissionRequest, FleetCommandError, FleetHandle, FleetHandleError, PermitLease,
        PermitReleaseReason, WriterHeadroom,
    },
    request::{
        BytePipeLimits, BytePipeReceiver, CancellationReason, CommitmentLimits,
        InboundAttemptEvent, OutputLimits, OutputMode, RequestCancellation, RequestExecutionError,
        RequestTask, RequestTaskConfig, ResponseLifetimeGuard, inbound_attempt_pipe,
    },
};

use super::{
    provider::fence_provider,
    state::{
        PilotSession, RequestRouteRegistration, RequestTable, RequestTableError, SessionDirectory,
    },
    telemetry::{PilotTelemetry, PilotTelemetryEvent},
};

const MAX_PROMPT_TOKENS: u64 = 32_768;
const DEFAULT_MAX_OUTPUT_TOKENS: u64 = 1_024;
const KV_BYTES_PER_TOKEN: u64 = 512 * 1_024;
const INBOUND_CONTROL_OVERHEAD: usize = 1024 * 1024;
const MAXIMUM_MESSAGES: usize = 256;
const MAXIMUM_TOOLS: usize = 128;
const MAXIMUM_CONTENT_PARTS: usize = 256;
const MAXIMUM_TOOL_CALLS_PER_MESSAGE: usize = 128;

/// Parsed, authenticated consumer work retained in the bounded request lane.
pub struct PilotRequestJob {
    pub plaintext: Vec<u8>,
    pub model: ModelId,
    pub output_mode: OutputMode,
    pub maximum_output_tokens: u64,
    pub traits: RequestTraits,
    pub demand: AdmissionDemand,
    pub input_permit: OwnedSemaphorePermit,
    pub response_permit: OwnedSemaphorePermit,
    pub response: Option<oneshot::Sender<Result<PilotResponse, PilotRequestError>>>,
    pub client_cancellation: CancellationToken,
}

/// Response body made visible only after authenticated content commitment.
pub struct PilotResponse {
    pub body: BytePipeReceiver<Vec<u8>>,
    pub output_mode: OutputMode,
}

#[derive(Clone)]
pub struct RequestDispatcher {
    sender: mpsc::Sender<PilotRequestJob>,
}

impl RequestDispatcher {
    pub fn try_dispatch(&self, job: PilotRequestJob) -> Result<(), RequestDispatchError> {
        self.sender.try_send(job).map_err(|error| match error {
            mpsc::error::TrySendError::Full(_) => RequestDispatchError::Full,
            mpsc::error::TrySendError::Closed(_) => RequestDispatchError::Closed,
        })
    }

    #[must_use]
    pub fn remaining_capacity(&self) -> usize {
        self.sender.capacity()
    }
}

pub struct RequestOwner {
    receiver: mpsc::Receiver<PilotRequestJob>,
    services: Arc<RequestServices>,
    slots: Arc<Semaphore>,
}

pub struct RequestServices {
    pub fleet: FleetHandle,
    pub directory: Arc<SessionDirectory>,
    pub requests: Arc<RequestTable>,
    pub terminal_store: Arc<crate::crypto::TerminalDispositionStore>,
    pub durable_io: DurableIoPool,
    pub telemetry: PilotTelemetry,
    pub request_timeout: Duration,
    pub permit_lease_ttl: Duration,
    pub maximum_output_bytes: usize,
    pub maximum_output_chunks: usize,
}

impl RequestOwner {
    pub fn new(
        queue_capacity: usize,
        maximum_requests: usize,
        services: Arc<RequestServices>,
    ) -> (Self, RequestDispatcher) {
        assert!(queue_capacity > 0);
        assert!(maximum_requests > 0);
        let (sender, receiver) = mpsc::channel(queue_capacity);
        (
            Self {
                receiver,
                services,
                slots: Arc::new(Semaphore::new(maximum_requests)),
            },
            RequestDispatcher { sender },
        )
    }

    pub async fn run(mut self, cancellation: CancellationToken) -> Result<(), RequestOwnerError> {
        let mut workers = JoinSet::new();
        loop {
            tokio::select! {
                biased;
                () = cancellation.cancelled() => {
                    self.receiver.close();
                    break;
                }
                joined = workers.join_next(), if !workers.is_empty() => {
                    if let Some(joined) = joined {
                        joined.map_err(|error| RequestOwnerError::TaskJoin(
                            Arc::from(error.to_string())
                        ))?;
                    }
                }
                permit = self.slots.clone().acquire_owned() => {
                    let permit = permit.map_err(|_| RequestOwnerError::SlotsClosed)?;
                    let job = tokio::select! {
                        biased;
                        () = cancellation.cancelled() => {
                            drop(permit);
                            self.receiver.close();
                            break;
                        }
                        job = self.receiver.recv() => job,
                    };
                    let Some(job) = job else {
                        if cancellation.is_cancelled() {
                            break;
                        }
                        return Err(RequestOwnerError::MailboxClosed);
                    };
                    let services = self.services.clone();
                    let shutdown = cancellation.clone();
                    workers.spawn(async move {
                        let _permit = permit;
                        run_job(job, services, shutdown).await;
                    });
                }
            }
        }

        while let Ok(job) = self.receiver.try_recv() {
            if let Some(response) = job.response {
                let _ = response.send(Err(PilotRequestError::Unavailable(Arc::from(
                    "pilot runtime is shutting down",
                ))));
            }
        }
        while let Some(joined) = workers.join_next().await {
            joined.map_err(|error| RequestOwnerError::TaskJoin(Arc::from(error.to_string())))?;
        }
        Ok(())
    }
}

pub fn parse_request_facts(
    plaintext: &[u8],
    configured_model: &ModelId,
    configured_alias: &str,
) -> Result<(ModelId, OutputMode, u64, RequestTraits, AdmissionDemand), PilotRequestError> {
    super::json_limits::validate_json_structure(plaintext)
        .map_err(|error| PilotRequestError::InvalidRequest(Arc::from(error.to_string())))?;
    let value: Value = serde_json::from_slice(plaintext)
        .map_err(|error| PilotRequestError::InvalidRequest(Arc::from(error.to_string())))?;
    let object = value.as_object().ok_or_else(|| {
        PilotRequestError::InvalidRequest(Arc::from("request body must be a JSON object"))
    })?;
    validate_request_cardinality(object)?;
    let requested = object
        .get("model")
        .and_then(Value::as_str)
        .ok_or_else(|| PilotRequestError::InvalidRequest(Arc::from("model is required")))?;
    if requested != configured_model.as_str() && requested != configured_alias {
        return Err(PilotRequestError::ModelNotFound(Arc::from(requested)));
    }
    let output_mode = if object
        .get("stream")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        OutputMode::Streaming
    } else {
        OutputMode::NonStreaming
    };
    let maximum_output_tokens = object
        .get("max_completion_tokens")
        .or_else(|| object.get("max_tokens"))
        .map_or(Ok(DEFAULT_MAX_OUTPUT_TOKENS), |value| {
            value.as_u64().filter(|value| *value > 0).ok_or_else(|| {
                PilotRequestError::InvalidRequest(Arc::from(
                    "max_completion_tokens must be a positive integer",
                ))
            })
        })?;
    let prompt_tokens = u64::try_from(plaintext.len()).unwrap_or(u64::MAX).max(1);
    let total_tokens = prompt_tokens
        .checked_add(maximum_output_tokens)
        .ok_or_else(|| PilotRequestError::InvalidRequest(Arc::from("token budget overflow")))?;
    if total_tokens > MAX_PROMPT_TOKENS {
        return Err(PilotRequestError::InvalidRequest(Arc::from(
            "request exceeds pilot model context",
        )));
    }
    let prompt = TokenCount::new(prompt_tokens);
    let completion = TokenCount::new(maximum_output_tokens);
    let total = TokenCount::new(total_tokens);
    let kv_bytes = total_tokens
        .checked_mul(KV_BYTES_PER_TOKEN)
        .ok_or_else(|| PilotRequestError::InvalidRequest(Arc::from("KV budget overflow")))?;
    let demand = AdmissionDemand::new(prompt, completion, KvBytes::new(kv_bytes))
        .map_err(|error| PilotRequestError::InvalidRequest(Arc::from(error.to_string())))?;
    let mut traits = RequestTraits::new(total);
    if object
        .get("tools")
        .and_then(Value::as_array)
        .is_some_and(|tools| !tools.is_empty())
    {
        traits = traits.requiring(Capability::Tools);
    }
    if object.get("response_format").is_some_and(|format| {
        format
            .get("type")
            .and_then(Value::as_str)
            .is_some_and(|kind| matches!(kind, "json_object" | "json_schema"))
    }) {
        traits = traits.requiring(Capability::StructuredOutput);
    }
    if request_contains_image(&value) {
        traits = traits.requiring(Capability::Multimodal);
    }
    Ok((
        configured_model.clone(),
        output_mode,
        maximum_output_tokens,
        traits,
        demand,
    ))
}

fn validate_request_cardinality(
    object: &serde_json::Map<String, Value>,
) -> Result<(), PilotRequestError> {
    let messages = match object.get("messages") {
        Some(value) => Some(value.as_array().ok_or_else(|| {
            PilotRequestError::InvalidRequest(Arc::from("messages must be an array"))
        })?),
        None => None,
    };
    if messages.is_some_and(|messages| messages.len() > MAXIMUM_MESSAGES) {
        return Err(PilotRequestError::InvalidRequest(Arc::from(format!(
            "messages may contain at most {MAXIMUM_MESSAGES} entries"
        ))));
    }
    let tools = match object.get("tools") {
        None | Some(Value::Null) => None,
        Some(value) => Some(value.as_array().ok_or_else(|| {
            PilotRequestError::InvalidRequest(Arc::from("tools must be an array"))
        })?),
    };
    if tools.is_some_and(|tools| tools.len() > MAXIMUM_TOOLS) {
        return Err(PilotRequestError::InvalidRequest(Arc::from(format!(
            "tools may contain at most {MAXIMUM_TOOLS} entries"
        ))));
    }
    for message in messages.into_iter().flatten() {
        let Some(message) = message.as_object() else {
            return Err(PilotRequestError::InvalidRequest(Arc::from(
                "each message must be an object",
            )));
        };
        if let Some(content) = message.get("content") {
            match content {
                Value::Array(parts) if parts.len() > MAXIMUM_CONTENT_PARTS => {
                    return Err(PilotRequestError::InvalidRequest(Arc::from(format!(
                        "message content may contain at most {MAXIMUM_CONTENT_PARTS} parts"
                    ))));
                }
                Value::Array(_) | Value::String(_) | Value::Null => {}
                _ => {
                    return Err(PilotRequestError::InvalidRequest(Arc::from(
                        "message content must be a string, array, or null",
                    )));
                }
            }
        }
        let tool_calls = match message.get("tool_calls") {
            None | Some(Value::Null) => None,
            Some(value) => Some(value.as_array().ok_or_else(|| {
                PilotRequestError::InvalidRequest(Arc::from("message tool_calls must be an array"))
            })?),
        };
        if tool_calls.is_some_and(|calls| calls.len() > MAXIMUM_TOOL_CALLS_PER_MESSAGE) {
            return Err(PilotRequestError::InvalidRequest(Arc::from(format!(
                "message tool_calls may contain at most {MAXIMUM_TOOL_CALLS_PER_MESSAGE} entries"
            ))));
        }
    }
    Ok(())
}

async fn run_job(
    mut job: PilotRequestJob,
    services: Arc<RequestServices>,
    shutdown: CancellationToken,
) {
    let started = Instant::now();
    services
        .telemetry
        .emit(PilotTelemetryEvent::RequestAccepted);
    let mut response = job.response.take();
    let result = execute_request(job, &services, &shutdown, &mut response).await;
    match result {
        Ok(()) => services
            .telemetry
            .emit(PilotTelemetryEvent::RequestCompleted {
                latency: started.elapsed(),
            }),
        Err(error) => {
            if let Some(response) = response.take() {
                let _ = response.send(Err(error));
            }
            services.telemetry.emit(PilotTelemetryEvent::RequestFailed {
                latency: started.elapsed(),
            });
        }
    }
}

async fn execute_request(
    job: PilotRequestJob,
    services: &RequestServices,
    shutdown: &CancellationToken,
    response_sender: &mut Option<oneshot::Sender<Result<PilotResponse, PilotRequestError>>>,
) -> Result<(), PilotRequestError> {
    if job.client_cancellation.is_cancelled() {
        return Err(PilotRequestError::Cancelled);
    }
    let now = epoch_millis()?;
    let timeout_ms = u64::try_from(services.request_timeout.as_millis())
        .map_err(|_| PilotRequestError::Internal(Arc::from("request timeout overflow")))?;
    let deadline_at = now
        .get()
        .checked_add(timeout_ms)
        .ok_or_else(|| PilotRequestError::Internal(Arc::from("request deadline overflow")))?;
    let deadline = AbsoluteDeadline::new(deadline_at)
        .map_err(|error| PilotRequestError::Internal(Arc::from(error.to_string())))?;
    let core_request_id = CoreRequestId::random();
    let wire_request_id = RequestId::new(*core_request_id.as_uuid().as_bytes());
    let profile = AdmissionProfile {
        model: job.model.clone(),
        traits: job.traits.clone(),
        demand: job.demand,
        writer_bytes: job.plaintext.len().saturating_mul(2).saturating_add(4_096),
        lease_ttl: services.permit_lease_ttl,
    };

    let primary = admit_primary(&profile, services).await?;
    let primary_plan = build_attempt_plan(
        primary,
        wire_request_id,
        &job.model,
        &job.plaintext,
        job.output_mode,
    )?;
    let runtime_deadline = tokio::time::Instant::now() + services.request_timeout;
    let target = Arc::new(CancellationTarget::default());
    target.install(&primary_plan.session, &primary_plan.identity);
    let cancellation_target = target.clone();
    let cancellation = RequestCancellation::new(job.client_cancellation.clone(), move |reason| {
        cancellation_target.cancel(reason);
    });
    let inbound_limits = BytePipeLimits {
        maximum_items: services.maximum_output_chunks.saturating_add(16),
        maximum_bytes: services
            .maximum_output_bytes
            .saturating_add(INBOUND_CONTROL_OVERHEAD),
    };
    let (inbound_sender, mut inbound) = inbound_attempt_pipe(inbound_limits, cancellation.clone())
        .map_err(|error| PilotRequestError::Internal(Arc::from(error.to_string())))?;
    let task_config = RequestTaskConfig {
        request_id: core_request_id,
        wire_request_id,
        deadline,
        funding_id: FundingId::random(),
        funding_amount: MicroUsd::new(1),
        model: job.model.clone(),
        request_digest: primary_plan.prepare.request_digest,
        maximum_prompt_tokens: MAX_PROMPT_TOKENS,
        output_mode: job.output_mode,
        output_limits: OutputLimits {
            maximum_chunk_bytes: darkbloom_coordinator_protocol::MAX_V2_CIPHERTEXT_LEN,
            maximum_output_bytes: services.maximum_output_bytes,
            maximum_chunks: services.maximum_output_chunks,
            maximum_output_tokens: job.maximum_output_tokens,
        },
        commitment_limits: CommitmentLimits {
            maximum_items: services.maximum_output_chunks,
            maximum_bytes: services.maximum_output_bytes,
        },
        pipe_limits: BytePipeLimits {
            maximum_items: services.maximum_output_chunks,
            maximum_bytes: services.maximum_output_bytes,
        },
    };
    let response_guard = ResponseLifetimeGuard::new(job.response_permit);
    let (mut task, response_body) =
        RequestTask::new(task_config, now, cancellation.clone(), Some(response_guard))
            .map_err(PilotRequestError::Execution)?;
    let mut response_body = Some(response_body);
    let registration = services.requests.insert(RequestRouteRegistration {
        request_id: wire_request_id,
        inbound: inbound_sender,
        seal: primary_plan.seal.clone(),
        provider_key: primary_plan.session.provider_key,
        session_identity: primary_plan.session.identity,
        attempt_identity: primary_plan.identity.clone(),
        cancellation: cancellation.clone(),
    })?;

    let mut provider_context = vec![primary_plan.session.fence.clone()];
    let primary_provider = primary_plan.session.identity.provider_id;
    let primary_result = run_attempt(
        &mut task,
        &mut inbound,
        primary_plan,
        AttemptKind::Primary,
        &provider_context,
        services,
        shutdown,
        runtime_deadline,
        response_sender,
        &mut response_body,
    )
    .await;

    let result = match primary_result {
        Ok(()) => Ok(()),
        Err(failure) if failure.precontent && !task.is_committed() => {
            if let Some(alternate) = admit_alternate(&profile, primary_provider, services).await? {
                let plan = build_attempt_plan(
                    alternate,
                    wire_request_id,
                    &job.model,
                    &job.plaintext,
                    job.output_mode,
                )?;
                provider_context.push(plan.session.fence.clone());
                target.install(&plan.session, &plan.identity);
                registration.replace_attempt(
                    plan.seal.clone(),
                    plan.session.provider_key,
                    plan.session.identity,
                    plan.identity.clone(),
                )?;
                run_attempt(
                    &mut task,
                    &mut inbound,
                    plan,
                    AttemptKind::Alternate,
                    &provider_context,
                    services,
                    shutdown,
                    runtime_deadline,
                    response_sender,
                    &mut response_body,
                )
                .await
                .map_err(|failure| failure.error)
            } else {
                Err(failure.error)
            }
        }
        Err(failure) => Err(failure.error),
    };

    drop(job.input_permit);
    if let Err(error) = result {
        let _ = task.cancel(
            if matches!(error, PilotRequestError::Timeout) {
                CancellationReason::DeadlineExpired
            } else {
                CancellationReason::RequestEnded
            },
            &request_context(&provider_context)?,
        );
        return Err(error);
    }
    registration.remove();
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn run_attempt(
    task: &mut RequestTask,
    inbound: &mut BytePipeReceiver<InboundAttemptEvent>,
    plan: AttemptPlan,
    kind: AttemptKind,
    providers: &[ProviderFence],
    services: &RequestServices,
    shutdown: &CancellationToken,
    runtime_deadline: tokio::time::Instant,
    response_sender: &mut Option<oneshot::Sender<Result<PilotResponse, PilotRequestError>>>,
    response_body: &mut Option<BytePipeReceiver<Vec<u8>>>,
) -> Result<(), AttemptFailure> {
    let lease_id = plan.lease.lease_id();
    let result = run_attempt_inner(
        task,
        inbound,
        plan,
        kind,
        providers,
        services,
        shutdown,
        runtime_deadline,
        response_sender,
        response_body,
    )
    .await;
    if result.is_err()
        && let Err(error) = release_permit(
            &services.fleet,
            lease_id,
            PermitReleaseReason::AttemptReleased,
        )
        .await
    {
        return Err(AttemptFailure::fatal(error));
    }
    result
}

#[allow(clippy::too_many_arguments)]
async fn run_attempt_inner(
    task: &mut RequestTask,
    inbound: &mut BytePipeReceiver<InboundAttemptEvent>,
    plan: AttemptPlan,
    kind: AttemptKind,
    providers: &[ProviderFence],
    services: &RequestServices,
    shutdown: &CancellationToken,
    runtime_deadline: tokio::time::Instant,
    response_sender: &mut Option<oneshot::Sender<Result<PilotResponse, PilotRequestError>>>,
    response_body: &mut Option<BytePipeReceiver<Vec<u8>>>,
) -> Result<(), AttemptFailure> {
    let context = request_context(providers).map_err(AttemptFailure::fatal)?;
    let (attempt_id, prepare_receipt) = match task.enqueue_prepare(
        kind,
        plan.prepare.clone(),
        plan.session.fence.clone(),
        plan.lease.permit_id(),
        &context,
        &plan.session.writer,
    ) {
        Ok(value) => value,
        Err(error) => {
            if matches!(&error, RequestExecutionError::OutboundRejected(_)) {
                fence_provider(
                    plan.session.identity,
                    "provider writer rejected Prepare",
                    &services.directory,
                    &services.requests,
                    &services.fleet,
                )
                .await;
            }
            release_permit(
                &services.fleet,
                plan.lease.lease_id(),
                PermitReleaseReason::BeforeWriterEnqueue,
            )
            .await
            .map_err(AttemptFailure::fatal)?;
            return Err(AttemptFailure::precontent(PilotRequestError::Execution(
                error,
            )));
        }
    };
    if let Err(error) = services
        .fleet
        .mark_writer_enqueued(plan.lease.lease_id())
        .await
    {
        task.cancellation().cancel(CancellationReason::RequestEnded);
        release_permit(
            &services.fleet,
            plan.lease.lease_id(),
            PermitReleaseReason::AttemptReleased,
        )
        .await
        .map_err(AttemptFailure::fatal)?;
        return Err(AttemptFailure::fatal(map_fleet_error(error)));
    }
    let mut renewal = PermitRenewal::new(
        services.fleet.clone(),
        plan.lease.lease_id(),
        services.permit_lease_ttl,
        runtime_deadline,
    );
    let delivery = match renewal
        .wait_delivery(prepare_receipt, task.cancellation(), shutdown)
        .await
    {
        Ok(delivery) => delivery,
        Err(error) => {
            if matches!(&error, PilotRequestError::Provider(_)) {
                fence_provider(
                    plan.session.identity,
                    "provider writer Prepare receipt failed",
                    &services.directory,
                    &services.requests,
                    &services.fleet,
                )
                .await;
            }
            return Err(AttemptFailure::fatal(error));
        }
    };
    report_writer_receipt(&services.fleet, &plan.session)
        .await
        .map_err(AttemptFailure::fatal)?;
    if matches!(
        &delivery,
        crate::provider::DeliveryState::SentUnknown | crate::provider::DeliveryState::Failed(_)
    ) {
        fence_provider(
            plan.session.identity,
            "provider writer Prepare delivery failed",
            &services.directory,
            &services.requests,
            &services.fleet,
        )
        .await;
    }
    if let Err(error) = task.observe_prepare_delivery(attempt_id, delivery, &context) {
        release_permit(
            &services.fleet,
            plan.lease.lease_id(),
            PermitReleaseReason::AttemptReleased,
        )
        .await
        .map_err(AttemptFailure::fatal)?;
        return Err(AttemptFailure::precontent(PilotRequestError::Execution(
            error,
        )));
    }

    match renewal
        .next_event(inbound, &plan.identity, task.cancellation(), shutdown)
        .await
        .map_err(AttemptFailure::fatal)?
    {
        InboundAttemptEvent::Prepared(prepared) => {
            if let Err(error) = task.accept_prepared(prepared) {
                fence_provider(
                    plan.session.identity,
                    "provider returned invalid Prepared facts",
                    &services.directory,
                    &services.requests,
                    &services.fleet,
                )
                .await;
                plan.session
                    .writer
                    .try_send_control_json(&CoordinatorControlMessage::Abort(Abort {
                        identity: plan.identity.clone(),
                        reason: Some("invalid prepared facts".to_owned()),
                    }))
                    .map_err(AttemptFailure::fatal)?;
                task.fail_pre_authorization(attempt_id, &context)
                    .map_err(AttemptFailure::fatal)?;
                return Err(AttemptFailure::precontent(PilotRequestError::Execution(
                    error,
                )));
            }
        }
        InboundAttemptEvent::StructuredError(error) => {
            task.fail_pre_authorization(attempt_id, &context)
                .map_err(AttemptFailure::fatal)?;
            release_permit(
                &services.fleet,
                plan.lease.lease_id(),
                PermitReleaseReason::AttemptReleased,
            )
            .await
            .map_err(AttemptFailure::fatal)?;
            return Err(AttemptFailure::precontent(structured_error(error.class)));
        }
        InboundAttemptEvent::StartAck(_)
        | InboundAttemptEvent::Chunk { .. }
        | InboundAttemptEvent::Terminal(_) => {
            return Err(AttemptFailure::fatal(PilotRequestError::Protocol(
                Arc::from("provider output arrived before Prepared"),
            )));
        }
    }

    let start_receipt = match task.enqueue_start(
        attempt_id,
        &request_context(providers).map_err(AttemptFailure::fatal)?,
    ) {
        Ok(receipt) => receipt,
        Err(error) => {
            if matches!(&error, RequestExecutionError::OutboundRejected(_)) {
                fence_provider(
                    plan.session.identity,
                    "provider writer rejected Start",
                    &services.directory,
                    &services.requests,
                    &services.fleet,
                )
                .await;
            }
            return Err(AttemptFailure::fatal(PilotRequestError::Execution(error)));
        }
    };
    let delivery = match renewal
        .wait_delivery(start_receipt, task.cancellation(), shutdown)
        .await
    {
        Ok(delivery) => delivery,
        Err(error) => {
            if matches!(&error, PilotRequestError::Provider(_)) {
                fence_provider(
                    plan.session.identity,
                    "provider writer Start receipt failed",
                    &services.directory,
                    &services.requests,
                    &services.fleet,
                )
                .await;
            }
            return Err(AttemptFailure::fatal(error));
        }
    };
    report_writer_receipt(&services.fleet, &plan.session)
        .await
        .map_err(AttemptFailure::fatal)?;
    if matches!(
        &delivery,
        crate::provider::DeliveryState::SentUnknown | crate::provider::DeliveryState::Failed(_)
    ) {
        fence_provider(
            plan.session.identity,
            "provider writer Start delivery failed",
            &services.directory,
            &services.requests,
            &services.fleet,
        )
        .await;
    }
    task.observe_start_delivery(attempt_id, delivery)
        .map_err(|error| AttemptFailure::fatal(PilotRequestError::Execution(error)))?;

    match renewal
        .next_event(inbound, &plan.identity, task.cancellation(), shutdown)
        .await
        .map_err(AttemptFailure::fatal)?
    {
        InboundAttemptEvent::StartAck(ack) => {
            task.accept_start_ack(&ack)
                .map_err(|error| AttemptFailure::fatal(PilotRequestError::Execution(error)))?;
        }
        InboundAttemptEvent::StructuredError(error) => {
            return Err(AttemptFailure::fatal(structured_error(error.class)));
        }
        InboundAttemptEvent::Prepared(_)
        | InboundAttemptEvent::Chunk { .. }
        | InboundAttemptEvent::Terminal(_) => {
            return Err(AttemptFailure::fatal(PilotRequestError::Protocol(
                Arc::from("provider output arrived before StartAck"),
            )));
        }
    }

    loop {
        let event = renewal
            .next_event(inbound, &plan.identity, task.cancellation(), shutdown)
            .await
            .map_err(AttemptFailure::fatal)?;
        match event {
            InboundAttemptEvent::Chunk { header, plaintext } => {
                task.accept_chunk(
                    &header,
                    plaintext,
                    &request_context(providers).map_err(AttemptFailure::fatal)?,
                )
                .map_err(|error| AttemptFailure::fatal(PilotRequestError::Execution(error)))?;
                if task.is_committed() && response_sender.is_some() {
                    let sender = response_sender
                        .take()
                        .expect("checked response sender presence");
                    let body = response_body
                        .take()
                        .expect("response body is sent exactly once");
                    let _ = sender.send(Ok(PilotResponse {
                        body,
                        output_mode: match task.state().has_first_content() {
                            true => {
                                // The configured mode is represented by whether
                                // bytes are emitted before terminal; the HTTP
                                // layer also retained the requested mode.
                                // `output_mode_for_task` reads the receiver
                                // behavior through this explicit plan value.
                                plan.output_mode
                            }
                            false => unreachable!("commit implies first content"),
                        },
                    }));
                }
            }
            InboundAttemptEvent::Terminal(terminal) => {
                let outcome = terminal.outcome;
                accept_terminal(task, &terminal, &plan.session, providers, services)
                    .await
                    .map_err(AttemptFailure::fatal)?;
                release_permit(
                    &services.fleet,
                    plan.lease.lease_id(),
                    PermitReleaseReason::Terminal,
                )
                .await
                .map_err(AttemptFailure::fatal)?;
                if response_sender.is_some() {
                    return Err(AttemptFailure::fatal(match outcome {
                        TerminalOutcome::Completed => PilotRequestError::Protocol(Arc::from(
                            "completed terminal arrived before content commitment",
                        )),
                        TerminalOutcome::Cancelled => PilotRequestError::Provider(Arc::from(
                            "provider cancelled before producing content",
                        )),
                        TerminalOutcome::Error => PilotRequestError::Provider(Arc::from(
                            "provider failed before producing content",
                        )),
                    }));
                }
                return match outcome {
                    TerminalOutcome::Completed => Ok(()),
                    TerminalOutcome::Cancelled => {
                        Err(AttemptFailure::fatal(PilotRequestError::Provider(
                            Arc::from("provider cancelled after producing content"),
                        )))
                    }
                    TerminalOutcome::Error => {
                        Err(AttemptFailure::fatal(PilotRequestError::Provider(
                            Arc::from("provider failed after producing content"),
                        )))
                    }
                };
            }
            InboundAttemptEvent::StructuredError(error) => {
                return Err(AttemptFailure::fatal(structured_error(error.class)));
            }
            InboundAttemptEvent::Prepared(_) | InboundAttemptEvent::StartAck(_) => {
                return Err(AttemptFailure::fatal(PilotRequestError::Protocol(
                    Arc::from("duplicate provider control message"),
                )));
            }
        }
    }
}

async fn accept_terminal(
    task: &mut RequestTask,
    terminal: &ProviderTerminal,
    session: &PilotSession,
    providers: &[ProviderFence],
    services: &RequestServices,
) -> Result<(), PilotRequestError> {
    let key = TerminalKey::from(&terminal.identity);
    let terminal_store = services.terminal_store.clone();
    let terminal_digest = terminal.terminal_digest;
    let historical = services
        .durable_io
        .run("resolve provider terminal disposition", move || {
            terminal_store.resolve_historical(key, terminal_digest)
        })
        .await
        .map_err(|error| PilotRequestError::Internal(Arc::from(error.to_string())))?;
    if matches!(historical, TerminalResolution::Conflict { .. }) {
        task.cancellation()
            .cancel(CancellationReason::ProtocolViolation);
        return Err(PilotRequestError::Protocol(Arc::from(
            "provider terminal conflicts with durable disposition",
        )));
    }
    let (core_disposition, wire_disposition) = match terminal.outcome {
        TerminalOutcome::Completed => (
            CoreTerminalDisposition::Settled {
                charged: MicroUsd::new(1),
            },
            TerminalDisposition::Settled,
        ),
        TerminalOutcome::Cancelled | TerminalOutcome::Error => (
            CoreTerminalDisposition::Released,
            TerminalDisposition::Released,
        ),
    };
    task.accept_terminal(
        terminal,
        core_disposition,
        &request_context(providers)?,
        |provider, generation, digest, signature| {
            session.verifies_terminal(provider, generation, digest, signature)
        },
    )?;
    let record = TerminalRecord {
        key,
        terminal_digest: terminal.terminal_digest,
        disposition: wire_disposition,
    };
    let terminal_store = services.terminal_store.clone();
    let resolution = services
        .durable_io
        .run("finalize provider terminal", move || {
            terminal_store.finalize(record)
        })
        .await
        .map_err(|error| PilotRequestError::Internal(Arc::from(error.to_string())))??;
    if matches!(resolution, TerminalResolution::Conflict { .. }) {
        return Err(PilotRequestError::Protocol(Arc::from(
            "provider terminal conflicts with durable disposition",
        )));
    }
    if let Err(error) =
        session
            .writer
            .try_send_control_json(&CoordinatorControlMessage::TerminalAck(TerminalAck {
                identity: terminal.identity.clone(),
                terminal_digest: terminal.terminal_digest,
                disposition: resolution.disposition(),
            }))
    {
        fence_provider(
            session.identity,
            "provider writer rejected terminal ACK",
            &services.directory,
            &services.requests,
            &services.fleet,
        )
        .await;
        return Err(error.into());
    }
    Ok(())
}

async fn report_writer_receipt(
    fleet: &FleetHandle,
    session: &PilotSession,
) -> Result<(), PilotRequestError> {
    let headroom = session.writer.headroom();
    let report = WriterHeadroom::new(
        headroom.revision,
        headroom.available_items,
        headroom.available_bytes,
    )
    .expect("provider writer revisions begin at one");
    match fleet
        .report_writer_headroom(
            session.fence.provider_id,
            session.fence.session_revision,
            report,
        )
        .await
    {
        Ok(())
        | Err(FleetHandleError::Command(
            FleetCommandError::ProviderNotFound(_) | FleetCommandError::StaleProviderFence(_),
        )) => Ok(()),
        Err(error) => Err(map_fleet_error(error)),
    }
}

#[derive(Clone)]
struct AdmissionProfile {
    model: ModelId,
    traits: RequestTraits,
    demand: AdmissionDemand,
    writer_bytes: usize,
    lease_ttl: Duration,
}

async fn admit_primary(
    profile: &AdmissionProfile,
    services: &RequestServices,
) -> Result<AdmittedSession, PilotRequestError> {
    let lease = services
        .fleet
        .admit(admission_request(profile))
        .await
        .map_err(map_fleet_error)?;
    let Some(session) = services.directory.inference_session(lease.provider()) else {
        release_permit(
            &services.fleet,
            lease.lease_id(),
            PermitReleaseReason::BeforeWriterEnqueue,
        )
        .await?;
        return Err(PilotRequestError::Capacity);
    };
    Ok(AdmittedSession { lease, session })
}

async fn admit_alternate(
    profile: &AdmissionProfile,
    excluded: darkbloom_coordinator_protocol::v2::ProviderId,
    services: &RequestServices,
) -> Result<Option<AdmittedSession>, PilotRequestError> {
    let snapshot = services.fleet.snapshot();
    let candidates: Vec<_> = snapshot
        .eligible_providers(&profile.model)
        .filter(|provider| provider.as_uuid().as_bytes() != excluded.as_bytes())
        .filter_map(|provider| {
            snapshot
                .provider(provider)
                .map(|runtime| (provider, runtime.provider().fence().clone()))
        })
        .collect();
    drop(snapshot);
    for (_, fence) in candidates {
        let request = admission_request(profile).with_expected_fence(fence.clone());
        match services.fleet.admit(request).await {
            Ok(lease) => {
                if let Some(session) = services.directory.inference_session(lease.provider()) {
                    return Ok(Some(AdmittedSession { lease, session }));
                }
                release_permit(
                    &services.fleet,
                    lease.lease_id(),
                    PermitReleaseReason::BeforeWriterEnqueue,
                )
                .await?;
            }
            Err(FleetHandleError::Command(
                FleetCommandError::NoEligibleProvider(_)
                | FleetCommandError::ProviderNotFound(_)
                | FleetCommandError::StaleProviderFence(_)
                | FleetCommandError::WriterItemHeadroom { .. }
                | FleetCommandError::WriterByteHeadroom { .. }
                | FleetCommandError::Admission(_),
            )) => {}
            Err(error) => return Err(map_fleet_error(error)),
        }
    }
    Ok(None)
}

fn admission_request(profile: &AdmissionProfile) -> AdmissionRequest {
    AdmissionRequest::any(
        profile.model.clone(),
        profile.traits.clone(),
        profile.demand,
        AdmissionKind::Regular,
        profile.writer_bytes,
        profile.lease_ttl,
    )
}

struct AdmittedSession {
    lease: PermitLease,
    session: PilotSession,
}

struct AttemptPlan {
    lease: PermitLease,
    session: PilotSession,
    seal: Arc<crate::crypto::ProviderRequestSeal>,
    identity: AttemptIdentity,
    prepare: Prepare,
    output_mode: OutputMode,
}

fn build_attempt_plan(
    admitted: AdmittedSession,
    request_id: RequestId,
    model: &ModelId,
    plaintext: &[u8],
    output_mode: OutputMode,
) -> Result<AttemptPlan, PilotRequestError> {
    let seal = Arc::new(
        seal_request_for_provider(admitted.session.provider_key, plaintext)
            .map_err(|error| PilotRequestError::Internal(Arc::from(error.to_string())))?,
    );
    let identity = AttemptIdentity {
        provider_id: admitted.session.identity.provider_id,
        provider_process_generation: admitted.session.identity.provider_process_generation,
        session_epoch: admitted.session.identity.session_epoch,
        request_id,
        attempt_id: AttemptId::new(*Uuid::new_v4().as_bytes()),
        reservation_id: ReservationId::new(*Uuid::new_v4().as_bytes()),
        lease_id: LeaseId::new(*admitted.lease.lease_id().as_uuid().as_bytes()),
    };
    let request_digest = Prepare::encrypted_payload_digest(seal.payload())
        .map_err(|error| PilotRequestError::Internal(Arc::from(error.to_string())))?;
    let prepare = Prepare {
        identity: identity.clone(),
        model: model.as_str().to_owned(),
        request_digest,
        encrypted_body: seal.payload().clone(),
    };
    Ok(AttemptPlan {
        lease: admitted.lease,
        session: admitted.session,
        seal,
        identity,
        prepare,
        output_mode,
    })
}

struct PermitRenewal {
    fleet: FleetHandle,
    lease_id: darkbloom_coordinator_core::ids::LeaseId,
    ttl: Duration,
    deadline: tokio::time::Instant,
    interval: tokio::time::Interval,
}

impl PermitRenewal {
    fn new(
        fleet: FleetHandle,
        lease_id: darkbloom_coordinator_core::ids::LeaseId,
        ttl: Duration,
        deadline: tokio::time::Instant,
    ) -> Self {
        let cadence = ttl
            .checked_div(2)
            .filter(|value| !value.is_zero())
            .unwrap_or(ttl);
        let mut interval = interval_at(tokio::time::Instant::now() + cadence, cadence);
        interval.set_missed_tick_behavior(MissedTickBehavior::Skip);
        Self {
            fleet,
            lease_id,
            ttl,
            deadline,
            interval,
        }
    }

    async fn wait_delivery(
        &mut self,
        receipt: crate::provider::DeliveryReceipt,
        cancellation: &RequestCancellation,
        shutdown: &CancellationToken,
    ) -> Result<crate::provider::DeliveryState, PilotRequestError> {
        let receipt = receipt.wait();
        let cancellation_token = cancellation.token();
        let deadline = tokio::time::sleep_until(self.deadline);
        tokio::pin!(receipt);
        tokio::pin!(deadline);
        loop {
            tokio::select! {
                biased;
                () = shutdown.cancelled() => {
                    cancellation.cancel(CancellationReason::RequestEnded);
                    return Err(PilotRequestError::Unavailable(Arc::from(
                        "pilot runtime is shutting down"
                    )));
                }
                () = cancellation_token.cancelled() => {
                    return Err(PilotRequestError::Cancelled);
                }
                () = &mut deadline => {
                    cancellation.cancel(CancellationReason::DeadlineExpired);
                    return Err(PilotRequestError::Timeout);
                }
                result = &mut receipt => {
                    return result.map_err(|error| {
                        PilotRequestError::Provider(Arc::from(error.to_string()))
                    });
                }
                _ = self.interval.tick() => self.renew(cancellation).await?,
            }
        }
    }

    async fn next_event(
        &mut self,
        inbound: &mut BytePipeReceiver<InboundAttemptEvent>,
        expected: &AttemptIdentity,
        cancellation: &RequestCancellation,
        shutdown: &CancellationToken,
    ) -> Result<InboundAttemptEvent, PilotRequestError> {
        let cancellation_token = cancellation.token();
        let deadline = tokio::time::sleep_until(self.deadline);
        tokio::pin!(deadline);
        loop {
            tokio::select! {
                biased;
                () = shutdown.cancelled() => {
                    cancellation.cancel(CancellationReason::RequestEnded);
                    return Err(PilotRequestError::Unavailable(Arc::from(
                        "pilot runtime is shutting down"
                    )));
                }
                () = cancellation_token.cancelled() => {
                    return Err(PilotRequestError::Cancelled);
                }
                () = &mut deadline => {
                    cancellation.cancel(CancellationReason::DeadlineExpired);
                    return Err(PilotRequestError::Timeout);
                }
                result = inbound.recv() => {
                    let event = result
                        .map_err(|error| PilotRequestError::Provider(Arc::from(error.to_string())))?
                        .ok_or_else(|| PilotRequestError::Provider(Arc::from(
                            "provider request event lane ended"
                        )))?;
                    if inbound_event_matches(&event, expected) {
                        return Ok(event);
                    }
                }
                _ = self.interval.tick() => self.renew(cancellation).await?,
            }
        }
    }

    async fn renew(&self, cancellation: &RequestCancellation) -> Result<(), PilotRequestError> {
        match self.fleet.renew_permit(self.lease_id, self.ttl).await {
            Ok(_) => Ok(()),
            Err(FleetHandleError::Command(FleetCommandError::LeaseNotFound(_))) => {
                cancellation.cancel(CancellationReason::RequestEnded);
                Err(PilotRequestError::Provider(Arc::from(
                    "provider capacity lease expired",
                )))
            }
            Err(error) => Err(map_fleet_error(error)),
        }
    }
}

fn inbound_event_matches(event: &InboundAttemptEvent, expected: &AttemptIdentity) -> bool {
    match event {
        InboundAttemptEvent::Prepared(message) => &message.identity == expected,
        InboundAttemptEvent::StartAck(message) => &message.identity == expected,
        InboundAttemptEvent::Chunk { header, .. } => header.attempt_identity() == *expected,
        InboundAttemptEvent::Terminal(message) => &message.identity == expected,
        InboundAttemptEvent::StructuredError(message) => &message.identity == expected,
    }
}

#[derive(Default)]
struct CancellationTarget {
    target: Mutex<Option<(crate::provider::ProviderWriterHandle, AttemptIdentity)>>,
}

impl CancellationTarget {
    fn install(&self, session: &PilotSession, identity: &AttemptIdentity) {
        *self
            .target
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) =
            Some((session.writer.clone(), identity.clone()));
    }

    fn cancel(&self, reason: CancellationReason) {
        let target = self
            .target
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        if let Some((writer, identity)) = target {
            let _ = writer.try_send_control_json(&CoordinatorControlMessage::Cancel(Cancel {
                identity,
                reason: Some(format!("{reason:?}")),
            }));
        }
    }
}

struct AttemptFailure {
    precontent: bool,
    error: PilotRequestError,
}

impl AttemptFailure {
    fn precontent(error: PilotRequestError) -> Self {
        Self {
            precontent: true,
            error,
        }
    }

    fn fatal(error: impl Into<PilotRequestError>) -> Self {
        Self {
            precontent: false,
            error: error.into(),
        }
    }
}

async fn release_permit(
    fleet: &FleetHandle,
    lease_id: darkbloom_coordinator_core::ids::LeaseId,
    reason: PermitReleaseReason,
) -> Result<(), PilotRequestError> {
    match fleet.release_permit(lease_id, reason).await {
        Ok(_) | Err(FleetHandleError::Command(FleetCommandError::LeaseNotFound(_))) => Ok(()),
        Err(error) => Err(map_fleet_error(error)),
    }
}

fn request_context(providers: &[ProviderFence]) -> Result<RequestContext, PilotRequestError> {
    let mut context = RequestContext::new(epoch_millis()?);
    for provider in providers {
        context = context.with_provider(provider.clone());
    }
    Ok(context)
}

fn epoch_millis() -> Result<EpochMillis, PilotRequestError> {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| PilotRequestError::Internal(Arc::from("system clock is before Unix epoch")))?
        .as_millis();
    u64::try_from(millis)
        .map(EpochMillis::new)
        .map_err(|_| PilotRequestError::Internal(Arc::from("system clock overflow")))
}

fn map_fleet_error(error: FleetHandleError) -> PilotRequestError {
    match error {
        FleetHandleError::Command(
            FleetCommandError::NoEligibleProvider(_)
            | FleetCommandError::LeaseLimit { .. }
            | FleetCommandError::WriterReservationLimit { .. }
            | FleetCommandError::WriterItemHeadroom { .. }
            | FleetCommandError::WriterByteHeadroom { .. }
            | FleetCommandError::Admission(_),
        ) => PilotRequestError::Capacity,
        FleetHandleError::ActorUnavailable => {
            PilotRequestError::Unavailable(Arc::from("fleet actor is unavailable"))
        }
        other => PilotRequestError::Provider(Arc::from(other.to_string())),
    }
}

fn structured_error(class: StructuredErrorClass) -> PilotRequestError {
    match class {
        StructuredErrorClass::InvalidRequest => {
            PilotRequestError::InvalidRequest(Arc::from("provider rejected request"))
        }
        StructuredErrorClass::Capacity
        | StructuredErrorClass::ModelNotReady
        | StructuredErrorClass::Draining => PilotRequestError::Capacity,
        StructuredErrorClass::Cancelled => PilotRequestError::Cancelled,
        StructuredErrorClass::Fault | StructuredErrorClass::Security => {
            PilotRequestError::Provider(Arc::from("provider execution failed"))
        }
    }
}

fn request_contains_image(value: &Value) -> bool {
    value
        .get("messages")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|message| message.get("content").and_then(Value::as_array))
        .flatten()
        .any(|part| {
            part.get("type")
                .and_then(Value::as_str)
                .is_some_and(|kind| matches!(kind, "image_url" | "input_image"))
        })
}

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum RequestDispatchError {
    #[error("pilot request queue is full")]
    Full,
    #[error("pilot request dispatcher is unavailable")]
    Closed,
}

#[derive(Debug, Error)]
pub enum RequestOwnerError {
    #[error("pilot request mailbox closed before shutdown")]
    MailboxClosed,
    #[error("pilot request worker slots are closed")]
    SlotsClosed,
    #[error("pilot request task join failed: {0}")]
    TaskJoin(Arc<str>),
}

#[derive(Debug, Error)]
pub enum PilotRequestError {
    #[error("invalid request: {0}")]
    InvalidRequest(Arc<str>),
    #[error("model {0} is not available")]
    ModelNotFound(Arc<str>),
    #[error("pilot fleet is at capacity")]
    Capacity,
    #[error("pilot request timed out")]
    Timeout,
    #[error("pilot request was cancelled")]
    Cancelled,
    #[error("provider failed: {0}")]
    Provider(Arc<str>),
    #[error("provider protocol violation: {0}")]
    Protocol(Arc<str>),
    #[error("pilot runtime unavailable: {0}")]
    Unavailable(Arc<str>),
    #[error("internal pilot error: {0}")]
    Internal(Arc<str>),
    #[error(transparent)]
    Execution(#[from] RequestExecutionError),
    #[error(transparent)]
    RequestTable(#[from] RequestTableError),
    #[error(transparent)]
    TerminalStore(#[from] crate::crypto::TerminalStoreError),
    #[error(transparent)]
    Writer(#[from] crate::provider::WriterEnqueueError),
}

impl From<RequestExecutionError> for AttemptFailure {
    fn from(error: RequestExecutionError) -> Self {
        Self::fatal(PilotRequestError::Execution(error))
    }
}

impl From<PilotRequestError> for AttemptFailure {
    fn from(error: PilotRequestError) -> Self {
        Self::fatal(error)
    }
}

impl From<crate::provider::WriterEnqueueError> for AttemptFailure {
    fn from(error: crate::provider::WriterEnqueueError) -> Self {
        Self::fatal(PilotRequestError::Writer(error))
    }
}
