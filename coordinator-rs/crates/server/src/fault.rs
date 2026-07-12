//! Deterministic, compile-time-only lifecycle fault injection.
//!
//! Production call sites supply their module, source file, symbol and execution
//! kind through the checkpoint macros. Tests can therefore prove that they hit
//! an actual lifecycle hook instead of calling this module directly. Delay
//! barriers are async-only and use Tokio notifications; synchronous hooks
//! reject delay plans when they are armed.

use std::{
    collections::BTreeMap,
    fmt, fs, io,
    path::{Path, PathBuf},
    process::Command,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, AtomicU8, AtomicU64, Ordering},
    },
    time::Duration,
};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};
use thiserror::Error;
use tokio::sync::Notify;

/// Every durable or transport lifecycle boundary covered by Objective 9.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum FaultPoint {
    /// Reservation transaction committed, before the result is trusted.
    ReserveCommit,
    /// Prepare was accepted by the finite provider writer.
    PrepareSent,
    /// Prepared facts were received and validated.
    PrepareReceived,
    /// Resize/start authorization committed.
    ResizeAuthorization,
    /// Start was staged and durably recorded as queued.
    StartQueued,
    /// Start send and flush completed.
    StartOnWire,
    /// Start began sending but delivery became ambiguous.
    StartSentUnknown,
    /// First authenticated content became consumer-visible.
    FirstChunk,
    /// A provider terminal reached the request owner.
    TerminalReceive,
    /// The sole terminal disposition committed durably.
    TerminalCommit,
    /// Terminal ACK was admitted to the provider writer.
    TerminalAck,
    /// An external side effect may have happened but is not confirmed.
    ExternalCallUnknown,
    /// A claimed fee page is about to be projected.
    FeeProjection,
    /// The dedicated ownership connection was lost.
    OwnershipConnectionLoss,
    /// Serving waits at the migration/mutation handoff lock.
    MigrationLock,
    /// Serving validates the immutable migration checksum catalog.
    MigrationChecksum,
    /// Provider-reader delivery is saturated or deliberately failed.
    ProviderReaderSaturation,
    /// Provider-writer admission is saturated or deliberately failed.
    ProviderWriterSaturation,
    /// A direct item/byte pipe reaches its finite bound.
    BytePipeOverflow,
    /// A replay proof/obligation is about to be fsynced.
    ReplayProofFsync,
    /// A terminal disposition is about to be fsynced.
    TerminalCacheFsync,
}

impl FaultPoint {
    /// Canonical complete matrix order.
    pub const ALL: [Self; 21] = [
        Self::ReserveCommit,
        Self::PrepareSent,
        Self::PrepareReceived,
        Self::ResizeAuthorization,
        Self::StartQueued,
        Self::StartOnWire,
        Self::StartSentUnknown,
        Self::FirstChunk,
        Self::TerminalReceive,
        Self::TerminalCommit,
        Self::TerminalAck,
        Self::ExternalCallUnknown,
        Self::FeeProjection,
        Self::OwnershipConnectionLoss,
        Self::MigrationLock,
        Self::MigrationChecksum,
        Self::ProviderReaderSaturation,
        Self::ProviderWriterSaturation,
        Self::BytePipeOverflow,
        Self::ReplayProofFsync,
        Self::TerminalCacheFsync,
    ];

    /// Stable machine-readable matrix key.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::ReserveCommit => "reserve_commit",
            Self::PrepareSent => "prepare_sent",
            Self::PrepareReceived => "prepare_received",
            Self::ResizeAuthorization => "resize_authorization",
            Self::StartQueued => "start_queued",
            Self::StartOnWire => "start_on_wire",
            Self::StartSentUnknown => "start_sent_unknown",
            Self::FirstChunk => "first_chunk",
            Self::TerminalReceive => "terminal_receive",
            Self::TerminalCommit => "terminal_commit",
            Self::TerminalAck => "terminal_ack",
            Self::ExternalCallUnknown => "external_call_unknown",
            Self::FeeProjection => "fee_projection",
            Self::OwnershipConnectionLoss => "ownership_connection_loss",
            Self::MigrationLock => "migration_lock",
            Self::MigrationChecksum => "migration_checksum",
            Self::ProviderReaderSaturation => "provider_reader_saturation",
            Self::ProviderWriterSaturation => "provider_writer_saturation",
            Self::BytePipeOverflow => "byte_pipe_overflow",
            Self::ReplayProofFsync => "replay_proof_fsync",
            Self::TerminalCacheFsync => "terminal_cache_fsync",
        }
    }

    /// Parses a stable machine-readable matrix key.
    #[must_use]
    pub fn from_name(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|point| point.as_str() == name)
    }

    /// Structural metadata expected from the production checkpoint.
    #[must_use]
    pub const fn definition(self) -> FaultDefinition {
        match self {
            Self::ReserveCommit => FaultDefinition::async_site(
                self,
                "src/ledger/reserve.rs",
                "LedgerService::reserve",
                &["exactly_one_disposition", "no_double_money_mutation"],
            ),
            Self::PrepareSent => FaultDefinition::sync_site(
                self,
                "src/request/task.rs",
                "RequestTask::observe_prepare_delivery",
                &["preauthorization_failover_only"],
            ),
            Self::PrepareReceived => FaultDefinition::sync_site(
                self,
                "src/request/task.rs",
                "RequestTask::accept_prepared",
                &["preauthorization_failover_only"],
            ),
            Self::ResizeAuthorization => FaultDefinition::async_site(
                self,
                "src/ledger/resize.rs",
                "LedgerService::resize_and_authorize",
                &["no_double_money_mutation", "no_failover_after_auth"],
            ),
            Self::StartQueued => FaultDefinition::async_site(
                self,
                "src/pilot/request.rs",
                "run_provider_attempt",
                &["no_failover_after_auth", "same_lease_recovery"],
            ),
            Self::StartOnWire => FaultDefinition::async_site(
                self,
                "src/pilot/request.rs",
                "run_provider_attempt",
                &["no_failover_after_auth", "same_lease_recovery"],
            ),
            Self::StartSentUnknown => FaultDefinition::async_site(
                self,
                "src/provider/writer.rs",
                "ProviderWriter::run",
                &["no_failover_after_auth", "same_lease_recovery"],
            ),
            Self::FirstChunk => FaultDefinition::sync_site(
                self,
                "src/request/task.rs",
                "RequestTask::accept_chunk",
                &["no_failover_after_auth", "exactly_one_disposition"],
            ),
            Self::TerminalReceive => FaultDefinition::async_site(
                self,
                "src/pilot/request.rs",
                "accept_terminal",
                &["exactly_one_disposition", "historical_ack"],
            ),
            Self::TerminalCommit => FaultDefinition::async_site(
                self,
                "src/pilot/request.rs",
                "accept_terminal",
                &[
                    "exactly_one_disposition",
                    "no_double_money_mutation",
                    "historical_ack",
                ],
            ),
            Self::TerminalAck => FaultDefinition::async_site(
                self,
                "src/pilot/request.rs",
                "send_terminal_ack",
                &["historical_ack", "exactly_one_disposition"],
            ),
            Self::ExternalCallUnknown => FaultDefinition::async_site(
                self,
                "src/surface/billing/withdrawal_recovery.rs",
                "WithdrawalRecoveryService::reconcile_transfer",
                &["exactly_one_disposition", "no_double_money_mutation"],
            ),
            Self::FeeProjection => FaultDefinition::async_site(
                self,
                "src/projection/fees.rs",
                "FeeProjectionService::complete",
                &["exactly_one_disposition", "same_lease_recovery"],
            ),
            Self::OwnershipConnectionLoss => FaultDefinition::async_site(
                self,
                "src/ownership.rs",
                "monitor_connection",
                &["quiescence_ownership_fencing"],
            ),
            Self::MigrationLock => FaultDefinition::async_site(
                self,
                "src/ownership.rs",
                "CoordinatorOwnership::acquire",
                &["quiescence_ownership_fencing"],
            ),
            Self::MigrationChecksum => FaultDefinition::async_site(
                self,
                "src/schema.rs",
                "validate_public_checksums",
                &["quiescence_ownership_fencing"],
            ),
            Self::ProviderReaderSaturation => FaultDefinition::async_site(
                self,
                "src/provider/types.rs",
                "SessionEventSender::send",
                &["bounded_backpressure", "quiescence_ownership_fencing"],
            ),
            Self::ProviderWriterSaturation => FaultDefinition::sync_site(
                self,
                "src/provider/writer.rs",
                "WriterQueue::try_enqueue_inner",
                &["bounded_backpressure", "no_failover_after_auth"],
            ),
            Self::BytePipeOverflow => FaultDefinition::sync_site(
                self,
                "src/request/byte_pipe.rs",
                "BytePipeSender::try_send",
                &["bounded_backpressure", "exactly_one_disposition"],
            ),
            Self::ReplayProofFsync => FaultDefinition::sync_site(
                self,
                "src/crypto/replay_store.rs",
                "ReplayProofStore::persist_provider",
                &["historical_ack", "exactly_one_disposition"],
            ),
            Self::TerminalCacheFsync => FaultDefinition::sync_site(
                self,
                "src/crypto/terminal_store.rs",
                "TerminalDispositionStore::finalize",
                &["historical_ack", "exactly_one_disposition"],
            ),
        }
    }
}

impl fmt::Display for FaultPoint {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

/// One-shot behavior applied when an armed checkpoint is reached.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FaultAction {
    /// Return an explicit injected failure to the lifecycle owner.
    Fail,
    /// Panic at the supervisor boundary, or abort in explicit child mode.
    Crash,
    /// Stop at the boundary until the controlling test releases it.
    Delay,
}

/// Observable result of executing one armed action.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FaultOutcome {
    /// [`FaultAction::Fail`] returned the injected error to its owner.
    FailureReturned,
    /// [`FaultAction::Delay`] resumed only after the controller released it.
    DelayReleased,
    /// [`FaultAction::Delay`] was waiting when its child process was terminated.
    DelayBlocked,
    /// [`FaultAction::Crash`] panicked at the in-process supervisor boundary.
    SupervisorPanicked,
    /// [`FaultAction::Crash`] aborted an explicitly configured child process.
    ProcessAborted,
}

impl FaultOutcome {
    fn matches(self, action: FaultAction) -> bool {
        matches!(
            (action, self),
            (FaultAction::Fail, Self::FailureReturned)
                | (FaultAction::Delay, Self::DelayReleased | Self::DelayBlocked)
                | (
                    FaultAction::Crash,
                    Self::SupervisorPanicked | Self::ProcessAborted
                )
        )
    }
}

/// Explicit one-shot failure returned by [`checkpoint`].
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
#[error("injected fault at {point}")]
pub struct InjectedFault {
    point: FaultPoint,
}

impl InjectedFault {
    /// Boundary that returned the failure.
    #[must_use]
    pub const fn point(self) -> FaultPoint {
        self.point
    }
}

/// Panic payload emitted by [`FaultAction::Crash`].
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct FaultCrash {
    /// Boundary that crashed.
    pub point: FaultPoint,
}

#[derive(Debug, Error)]
pub enum FaultControlError {
    /// Tests must isolate one active plan per process.
    #[error("fault {active} is already armed")]
    AlreadyArmed {
        /// Existing active point.
        active: FaultPoint,
    },
    /// The exact armed boundary was not reached within the test deadline.
    #[error("fault {point} was not reached within {timeout:?}")]
    WaitTimeout {
        /// Expected point.
        point: FaultPoint,
        /// Finite wait bound.
        timeout: Duration,
    },
    /// Delay cannot be installed on a synchronous production call site.
    #[error("fault {point} is synchronous and does not support delay")]
    DelayUnsupported {
        /// Synchronous point.
        point: FaultPoint,
    },
    /// The guard has not observed its production checkpoint.
    #[error("fault {point} was not hit")]
    NotHit {
        /// Expected point.
        point: FaultPoint,
    },
    /// Child abort mode is guarded by an explicit child-only environment bit.
    #[error("child abort mode is unavailable outside a fault child process")]
    ChildAbortModeUnavailable,
    /// Receipt or registry artifact could not be emitted.
    #[error("write fault evidence: {0}")]
    Evidence(#[from] FaultEvidenceError),
}

/// Whether a production checkpoint may await an async delay barrier.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FaultHookKind {
    /// Tokio task checkpoint.
    Async,
    /// Non-async checkpoint; delay plans are rejected.
    Sync,
}

/// Owned runtime site suitable for cross-process crash evidence.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct FaultExecutionSite {
    /// Stable hook identifier.
    pub hook_id: String,
    /// Source path supplied by `file!()`.
    pub file: String,
    /// Module supplied by `module_path!()`.
    pub module: String,
    /// Function or method containing the checkpoint.
    pub symbol: String,
    /// Source line supplied by `line!()`.
    pub line: u32,
    /// Async or sync checkpoint implementation.
    pub kind: FaultHookKind,
}

/// Exact action execution captured at a production checkpoint.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct FaultExecution {
    /// Production hook that fired.
    pub hook_id: String,
    /// Action armed by the test controller.
    pub armed_action: FaultAction,
    /// Action branch actually executed by the production checkpoint.
    pub executed_action: FaultAction,
    /// Result actually executed by the checkpoint.
    pub outcome: FaultOutcome,
    /// OS process that executed the action.
    pub process_id: u32,
    /// One evidence-run identity shared by registry and receipts.
    pub run_id: String,
    /// Source commit under test.
    pub commit: String,
    /// Exact production call site.
    pub site: FaultExecutionSite,
}

impl FaultExecution {
    fn validate(&self) -> Result<FaultPoint, FaultEvidenceError> {
        let point =
            FaultPoint::from_name(&self.hook_id).ok_or(FaultEvidenceError::InvalidExecution)?;
        let expected = point.definition();
        if self.process_id == 0
            || self.site.hook_id != self.hook_id
            || !self.site.file.ends_with(expected.file)
            || self.site.symbol != expected.symbol
            || self.site.kind != expected.kind
            || self.site.module.is_empty()
            || self.site.line == 0
            || self.armed_action != self.executed_action
            || !self.outcome.matches(self.executed_action)
        {
            return Err(FaultEvidenceError::InvalidExecution);
        }
        Ok(point)
    }
}

/// Canonical structural definition for one named lifecycle boundary.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub struct FaultDefinition {
    /// Stable hook identifier.
    pub id: &'static str,
    /// Production source file, relative to the server crate.
    pub file: &'static str,
    /// Production function or method containing the checkpoint.
    pub symbol: &'static str,
    /// Execution kind.
    pub kind: FaultHookKind,
    /// Recovery guarantees proved by executable validators.
    pub guarantees: &'static [&'static str],
}

impl FaultDefinition {
    const fn async_site(
        point: FaultPoint,
        file: &'static str,
        symbol: &'static str,
        guarantees: &'static [&'static str],
    ) -> Self {
        Self {
            id: point.as_str(),
            file,
            symbol,
            kind: FaultHookKind::Async,
            guarantees,
        }
    }

    const fn sync_site(
        point: FaultPoint,
        file: &'static str,
        symbol: &'static str,
        guarantees: &'static [&'static str],
    ) -> Self {
        Self {
            id: point.as_str(),
            file,
            symbol,
            kind: FaultHookKind::Sync,
            guarantees,
        }
    }
}

/// Runtime metadata captured from the actual macro invocation that fired.
#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct FaultHit {
    /// Stable hook identifier.
    pub hook_id: &'static str,
    /// Source path supplied by `file!()` at the production hook.
    pub file: &'static str,
    /// Module supplied by `module_path!()` at the production hook.
    pub module: &'static str,
    /// Function or method declared by the production hook.
    pub symbol: &'static str,
    /// Source line supplied by `line!()` at the production hook.
    pub line: u32,
    /// Async or sync checkpoint implementation that fired.
    pub kind: FaultHookKind,
}

impl FaultHit {
    fn validate(&self, point: FaultPoint) -> Result<(), InjectedFault> {
        let expected = point.definition();
        if self.hook_id != expected.id
            || !self.file.ends_with(expected.file)
            || self.symbol != expected.symbol
            || self.kind != expected.kind
        {
            return Err(InjectedFault { point });
        }
        Ok(())
    }

    fn execution(&self, action: FaultAction, outcome: FaultOutcome) -> FaultExecution {
        FaultExecution {
            hook_id: self.hook_id.to_owned(),
            armed_action: action,
            executed_action: action,
            outcome,
            process_id: std::process::id(),
            run_id: std::env::var("DARKBLOOM_FAULT_RECEIPT_RUN_ID").unwrap_or_default(),
            commit: std::env::var("DARKBLOOM_FAULT_RECEIPT_COMMIT").unwrap_or_default(),
            site: FaultExecutionSite {
                hook_id: self.hook_id.to_owned(),
                file: self.file.to_owned(),
                module: self.module.to_owned(),
                symbol: self.symbol.to_owned(),
                line: self.line,
                kind: self.kind,
            },
        }
    }
}

#[derive(Debug)]
struct FaultSignal {
    hit: AtomicBool,
    hit_count: AtomicU64,
    site: Mutex<Option<FaultHit>>,
    execution: Mutex<Option<FaultExecution>>,
    observed: Notify,
    delay_released: AtomicBool,
    delay_release: Notify,
}

impl FaultSignal {
    fn new() -> Self {
        Self {
            hit: AtomicBool::new(false),
            hit_count: AtomicU64::new(0),
            site: Mutex::new(None),
            execution: Mutex::new(None),
            observed: Notify::new(),
            delay_released: AtomicBool::new(false),
            delay_release: Notify::new(),
        }
    }

    fn mark_hit(&self, site: FaultHit) {
        *self
            .site
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(site);
        self.hit_count.fetch_add(1, Ordering::AcqRel);
        self.hit.store(true, Ordering::Release);
        self.observed.notify_waiters();
    }

    async fn wait_for_release(&self) {
        loop {
            let released = self.delay_release.notified();
            if self.delay_released.load(Ordering::Acquire) {
                return;
            }
            released.await;
        }
    }

    fn release(&self) {
        self.delay_released.store(true, Ordering::Release);
        self.delay_release.notify_waiters();
    }

    fn mark_outcome(&self, action: FaultAction, outcome: FaultOutcome) {
        let site = self
            .site
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
            .expect("fault outcome follows a marked production hit");
        *self
            .execution
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) =
            Some(site.execution(action, outcome));
    }

    fn execution(&self) -> Option<FaultExecution> {
        self.execution
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }
}

#[derive(Debug)]
struct ActiveFault {
    id: u64,
    point: FaultPoint,
    action: FaultAction,
    triggered: bool,
    signal: Arc<FaultSignal>,
}

static ACTIVE_FAULT: OnceLock<Mutex<Option<ActiveFault>>> = OnceLock::new();
static NEXT_FAULT_ID: AtomicU64 = AtomicU64::new(1);

fn active_fault() -> &'static Mutex<Option<ActiveFault>> {
    ACTIVE_FAULT.get_or_init(|| Mutex::new(None))
}

/// Exclusive process-local ownership of one deterministic fault plan.
#[derive(Debug)]
pub struct FaultGuard {
    id: u64,
    point: FaultPoint,
    action: FaultAction,
    signal: Arc<FaultSignal>,
}

impl FaultGuard {
    /// Waits for the exact checkpoint without polling or sleeping.
    pub async fn wait_until_hit(&self, wait_timeout: Duration) -> Result<(), FaultControlError> {
        if self.signal.hit.load(Ordering::Acquire) {
            return Ok(());
        }
        let wait = async {
            loop {
                let observed = self.signal.observed.notified();
                if self.signal.hit.load(Ordering::Acquire) {
                    return;
                }
                observed.await;
            }
        };
        tokio::time::timeout(wait_timeout, wait)
            .await
            .map_err(|_| FaultControlError::WaitTimeout {
                point: self.point,
                timeout: wait_timeout,
            })
    }

    /// Releases a delayed checkpoint. It is harmless for fail/crash plans.
    pub fn release(&self) {
        self.signal.release();
    }

    /// Requires that this guard fired at its registered production site.
    pub fn assert_hit(&self) -> Result<FaultHit, FaultControlError> {
        if !self.signal.hit.load(Ordering::Acquire) {
            return Err(FaultControlError::NotHit { point: self.point });
        }
        self.signal
            .site
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
            .ok_or(FaultControlError::NotHit { point: self.point })
    }

    /// Requires the armed action to have reached its observable outcome.
    pub fn assert_execution(&self) -> Result<FaultExecution, FaultControlError> {
        let execution = self
            .signal
            .execution()
            .ok_or(FaultControlError::NotHit { point: self.point })?;
        if execution.armed_action != self.action
            || execution.executed_action != self.action
            || execution.hook_id != self.point.as_str()
            || !execution.outcome.matches(self.action)
        {
            return Err(FaultEvidenceError::InvalidExecution.into());
        }
        Ok(execution)
    }

    /// Number of times the one-shot hook fired.
    #[must_use]
    pub fn hit_count(&self) -> u64 {
        self.signal.hit_count.load(Ordering::Acquire)
    }

    /// Armed point.
    #[must_use]
    pub const fn point(&self) -> FaultPoint {
        self.point
    }

    /// Armed action.
    #[must_use]
    pub const fn action(&self) -> FaultAction {
        self.action
    }
}

impl Drop for FaultGuard {
    fn drop(&mut self) {
        self.signal.release();
        let mut active = active_fault()
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if active.as_ref().is_some_and(|fault| fault.id == self.id) {
            *active = None;
        }
    }
}

/// Arms one named, one-shot checkpoint.
pub fn arm(point: FaultPoint, action: FaultAction) -> Result<FaultGuard, FaultControlError> {
    if action == FaultAction::Delay && point.definition().kind == FaultHookKind::Sync {
        return Err(FaultControlError::DelayUnsupported { point });
    }
    let mut active = active_fault()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if let Some(existing) = active.as_ref() {
        return Err(FaultControlError::AlreadyArmed {
            active: existing.point,
        });
    }
    let id = NEXT_FAULT_ID.fetch_add(1, Ordering::Relaxed);
    let signal = Arc::new(FaultSignal::new());
    *active = Some(ActiveFault {
        id,
        point,
        action,
        triggered: false,
        signal: signal.clone(),
    });
    Ok(FaultGuard {
        id,
        point,
        action,
        signal,
    })
}

/// Returns whether the exact one-shot plan is armed but not yet triggered.
///
/// Transport futures use this only to create a deterministic pending edge
/// after `start_send`; the production checkpoint still owns execution.
#[must_use]
pub fn is_armed(point: FaultPoint) -> bool {
    active_fault()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .is_some_and(|fault| fault.point == point && !fault.triggered)
}

const CRASH_MODE_PANIC: u8 = 0;
const CRASH_MODE_CHILD_ABORT: u8 = 1;
static CRASH_MODE: AtomicU8 = AtomicU8::new(CRASH_MODE_PANIC);

/// Enables process abort for crash actions inside an explicit child fixture.
///
/// The child launcher must set `DARKBLOOM_FAULT_CHILD_ABORT=1`. Normal tests
/// retain a catchable supervisor panic and cannot accidentally abort.
pub fn enable_child_abort_mode() -> Result<(), FaultControlError> {
    if std::env::var("DARKBLOOM_FAULT_CHILD_ABORT").as_deref() != Ok("1") {
        return Err(FaultControlError::ChildAbortModeUnavailable);
    }
    CRASH_MODE.store(CRASH_MODE_CHILD_ABORT, Ordering::Release);
    Ok(())
}

/// Executes an armed asynchronous checkpoint once.
///
/// Unarmed checkpoints and later visits to a one-shot checkpoint are no-ops.
pub async fn checkpoint_async(
    point: FaultPoint,
    file: &'static str,
    module: &'static str,
    line: u32,
    symbol: &'static str,
) -> Result<(), InjectedFault> {
    let site = FaultHit {
        hook_id: point.as_str(),
        file,
        module,
        symbol,
        line,
        kind: FaultHookKind::Async,
    };
    site.validate(point)?;
    match take_action(point, site) {
        None => Ok(()),
        Some((FaultAction::Fail, signal)) => {
            signal.mark_outcome(FaultAction::Fail, FaultOutcome::FailureReturned);
            Err(InjectedFault { point })
        }
        Some((FaultAction::Crash, signal)) => crash(point, &signal),
        Some((FaultAction::Delay, signal)) => {
            signal.mark_outcome(FaultAction::Delay, FaultOutcome::DelayBlocked);
            persist_child_execution_marker(&signal);
            signal.wait_for_release().await;
            signal.mark_outcome(FaultAction::Delay, FaultOutcome::DelayReleased);
            Ok(())
        }
    }
}

/// Executes an armed synchronous checkpoint once.
///
/// Delay plans cannot be armed for these points.
pub fn checkpoint_sync(
    point: FaultPoint,
    file: &'static str,
    module: &'static str,
    line: u32,
    symbol: &'static str,
) -> Result<(), InjectedFault> {
    let site = FaultHit {
        hook_id: point.as_str(),
        file,
        module,
        symbol,
        line,
        kind: FaultHookKind::Sync,
    };
    site.validate(point)?;
    match take_action(point, site) {
        None => Ok(()),
        Some((FaultAction::Fail, signal)) => {
            signal.mark_outcome(FaultAction::Fail, FaultOutcome::FailureReturned);
            Err(InjectedFault { point })
        }
        Some((FaultAction::Crash, signal)) => crash(point, &signal),
        Some((FaultAction::Delay, _)) => Err(InjectedFault { point }),
    }
}

fn take_action(point: FaultPoint, site: FaultHit) -> Option<(FaultAction, Arc<FaultSignal>)> {
    let action = {
        let mut active = active_fault()
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let active = active.as_mut()?;
        if active.point != point || active.triggered {
            return None;
        }
        active.triggered = true;
        active.signal.mark_hit(site);
        (active.action, active.signal.clone())
    };
    Some(action)
}

fn crash(point: FaultPoint, signal: &FaultSignal) -> ! {
    if CRASH_MODE.load(Ordering::Acquire) == CRASH_MODE_CHILD_ABORT {
        signal.mark_outcome(FaultAction::Crash, FaultOutcome::ProcessAborted);
        persist_child_execution_marker(signal);
        std::process::abort();
    }
    signal.mark_outcome(FaultAction::Crash, FaultOutcome::SupervisorPanicked);
    std::panic::panic_any(FaultCrash { point })
}

fn persist_child_execution_marker(signal: &FaultSignal) {
    if let Some(path) = std::env::var_os("DARKBLOOM_FAULT_CHILD_HIT_PATH")
        && let Some(execution) = signal.execution()
    {
        let _ = write_abort_marker(Path::new(&path), &execution);
    }
}

fn write_abort_marker(path: &Path, execution: &FaultExecution) -> Result<(), FaultEvidenceError> {
    let mut file = fs::File::create(path)?;
    serde_json::to_writer(&mut file, execution)?;
    file.sync_all()?;
    Ok(())
}

/// Reads and structurally validates an execution marker written before child abort.
pub fn read_abort_marker(path: &Path) -> Result<FaultExecution, FaultEvidenceError> {
    let marker: FaultExecution = serde_json::from_slice(&fs::read(path)?)?;
    marker.validate()?;
    Ok(marker)
}

/// Emits the signed, compiled instrumentation registry when evidence output is configured.
pub fn write_instrumentation_registry() -> Result<(), FaultEvidenceError> {
    let Some(configuration) = EvidenceConfiguration::from_environment()? else {
        return Ok(());
    };
    let hooks = FaultPoint::ALL
        .into_iter()
        .map(FaultPoint::definition)
        .collect();
    let payload = RegistryPayload {
        schema_version: 1,
        artifact: "fault-instrumentation-registry",
        objective: 9,
        run_id: configuration.run_id.clone(),
        commit: configuration.commit.clone(),
        process_id: std::process::id(),
        hooks,
    };
    configuration.write_signed("instrumentation-registry.json", &payload)
}

/// Emits one signed executable receipt after assertions have passed.
pub fn write_test_receipt(
    test_id: &str,
    guards: &[&FaultGuard],
    invariant_assertions: &[&str],
) -> Result<(), FaultControlError> {
    let mut executions = Vec::with_capacity(guards.len());
    for guard in guards {
        if guard.hit_count() != 1 {
            return Err(FaultEvidenceError::InvalidExecution.into());
        }
        executions.push(guard.assert_execution()?);
    }
    write_test_receipt_from_executions(test_id, &executions, invariant_assertions)
}

/// Emits a signed receipt for executions observed in a child process.
pub fn write_test_receipt_from_executions(
    test_id: &str,
    executions: &[FaultExecution],
    invariant_assertions: &[&str],
) -> Result<(), FaultControlError> {
    let Some(configuration) = EvidenceConfiguration::from_environment()? else {
        return Ok(());
    };
    if test_id.is_empty() || invariant_assertions.is_empty() || executions.is_empty() {
        return Err(FaultEvidenceError::InvalidReceipt.into());
    }
    let mut hooks = BTreeMap::<String, ReceiptHook>::new();
    for execution in executions {
        execution.validate()?;
        if execution.run_id != configuration.run_id || execution.commit != configuration.commit {
            return Err(FaultEvidenceError::InvalidExecution.into());
        }
        let hook = hooks
            .entry(execution.hook_id.clone())
            .or_insert_with(|| ReceiptHook {
                hook_id: execution.hook_id.clone(),
                hit_count: 0,
                executions: Vec::new(),
            });
        hook.hit_count = hook.hit_count.saturating_add(1);
        hook.executions.push(execution.clone());
    }
    let payload = ReceiptPayload {
        schema_version: 1,
        artifact: "fault-test-receipt",
        objective: 9,
        test_id,
        run_id: &configuration.run_id,
        commit: &configuration.commit,
        process_id: std::process::id(),
        hooks: hooks.into_values().collect(),
        invariant_assertions: invariant_assertions
            .iter()
            .map(|assertion| InvariantAssertion {
                id: assertion,
                passed: true,
            })
            .collect(),
    };
    let filename = format!("receipt-{}.json", sanitize_filename(test_id));
    configuration.write_signed(&filename, &payload)?;
    Ok(())
}

#[derive(Debug, Error)]
pub enum FaultEvidenceError {
    #[error("fault evidence environment is incomplete")]
    IncompleteEnvironment,
    #[error("fault receipt is missing hooks or invariant assertions")]
    InvalidReceipt,
    #[error("fault execution action, outcome, process, run, or site is invalid")]
    InvalidExecution,
    #[error("fault evidence I/O: {0}")]
    Io(#[from] io::Error),
    #[error("serialize fault evidence: {0}")]
    Serialize(#[from] serde_json::Error),
    #[error("OpenSSL {operation} failed: {detail}")]
    OpenSsl {
        operation: &'static str,
        detail: String,
    },
}

#[derive(Debug)]
struct EvidenceConfiguration {
    directory: PathBuf,
    signing_key: PathBuf,
    run_id: String,
    commit: String,
}

impl EvidenceConfiguration {
    fn from_environment() -> Result<Option<Self>, FaultEvidenceError> {
        let directory = std::env::var_os("DARKBLOOM_FAULT_RECEIPT_DIR");
        let signing_key = std::env::var_os("DARKBLOOM_FAULT_RECEIPT_SIGNING_KEY");
        let run_id = std::env::var("DARKBLOOM_FAULT_RECEIPT_RUN_ID").ok();
        let commit = std::env::var("DARKBLOOM_FAULT_RECEIPT_COMMIT").ok();
        if directory.is_none() && signing_key.is_none() && run_id.is_none() && commit.is_none() {
            return Ok(None);
        }
        let (Some(directory), Some(signing_key), Some(run_id), Some(commit)) =
            (directory, signing_key, run_id, commit)
        else {
            return Err(FaultEvidenceError::IncompleteEnvironment);
        };
        if run_id.is_empty() || commit.is_empty() {
            return Err(FaultEvidenceError::IncompleteEnvironment);
        }
        Ok(Some(Self {
            directory: directory.into(),
            signing_key: signing_key.into(),
            run_id,
            commit,
        }))
    }

    fn write_signed(
        &self,
        filename: &str,
        payload: &impl Serialize,
    ) -> Result<(), FaultEvidenceError> {
        fs::create_dir_all(&self.directory)?;
        let payload = serde_json::to_vec(payload)?;
        let signature = openssl(
            &[
                "dgst",
                "-sha256",
                "-sign",
                self.signing_key
                    .to_str()
                    .ok_or(FaultEvidenceError::IncompleteEnvironment)?,
            ],
            &payload,
            "sign receipt",
        )?;
        let public_key = openssl(
            &[
                "pkey",
                "-in",
                self.signing_key
                    .to_str()
                    .ok_or(FaultEvidenceError::IncompleteEnvironment)?,
                "-pubout",
                "-outform",
                "DER",
            ],
            &[],
            "derive receipt public key",
        )?;
        let envelope = SignedEnvelope {
            schema_version: 1,
            signed_payload: STANDARD.encode(payload),
            signature: ReceiptSignature {
                algorithm: "openssl-dgst-sha256",
                key_id: hex_digest(Sha256::digest(public_key)),
                value: STANDARD.encode(signature),
            },
        };
        let target = self.directory.join(filename);
        let temporary = self.directory.join(format!(".{filename}.tmp"));
        let mut output = fs::File::create(&temporary)?;
        serde_json::to_writer_pretty(&mut output, &envelope)?;
        use io::Write as _;
        output.write_all(b"\n")?;
        output.sync_all()?;
        fs::rename(temporary, target)?;
        Ok(())
    }
}

fn openssl(
    arguments: &[&str],
    input: &[u8],
    operation: &'static str,
) -> Result<Vec<u8>, FaultEvidenceError> {
    use std::process::Stdio;
    let mut child = Command::new("openssl")
        .args(arguments)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(FaultEvidenceError::Io)?;
    if !input.is_empty() {
        use io::Write as _;
        child
            .stdin
            .take()
            .ok_or(FaultEvidenceError::IncompleteEnvironment)?
            .write_all(input)?;
    }
    let output = child.wait_with_output()?;
    if !output.status.success() {
        return Err(FaultEvidenceError::OpenSsl {
            operation,
            detail: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        });
    }
    Ok(output.stdout)
}

fn hex_digest(digest: impl AsRef<[u8]>) -> String {
    use fmt::Write as _;
    digest
        .as_ref()
        .iter()
        .fold(String::new(), |mut output, byte| {
            write!(output, "{byte:02x}").expect("write to string");
            output
        })
}

fn sanitize_filename(value: &str) -> String {
    value
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '-' | '_') {
                character
            } else {
                '-'
            }
        })
        .collect()
}

#[derive(Serialize)]
struct RegistryPayload {
    schema_version: u32,
    artifact: &'static str,
    objective: u32,
    run_id: String,
    commit: String,
    process_id: u32,
    hooks: Vec<FaultDefinition>,
}

#[derive(Serialize)]
struct ReceiptPayload<'a> {
    schema_version: u32,
    artifact: &'static str,
    objective: u32,
    test_id: &'a str,
    run_id: &'a str,
    commit: &'a str,
    process_id: u32,
    hooks: Vec<ReceiptHook>,
    invariant_assertions: Vec<InvariantAssertion<'a>>,
}

#[derive(Serialize)]
struct ReceiptHook {
    hook_id: String,
    hit_count: u64,
    executions: Vec<FaultExecution>,
}

#[derive(Serialize)]
struct InvariantAssertion<'a> {
    id: &'a str,
    passed: bool,
}

#[derive(Serialize)]
struct SignedEnvelope {
    schema_version: u32,
    signed_payload: String,
    signature: ReceiptSignature,
}

#[derive(Serialize)]
struct ReceiptSignature {
    algorithm: &'static str,
    key_id: String,
    value: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_unique_and_round_trip() {
        let mut names = std::collections::BTreeSet::new();
        for point in FaultPoint::ALL {
            assert!(names.insert(point.as_str()));
            assert_eq!(FaultPoint::from_name(point.as_str()), Some(point));
        }
    }

    #[test]
    fn definitions_are_unique_and_complete() {
        let mut names = std::collections::BTreeSet::new();
        for point in FaultPoint::ALL {
            let definition = point.definition();
            assert!(names.insert(definition.id));
            assert!(!definition.file.is_empty());
            assert!(!definition.symbol.is_empty());
            assert!(!definition.guarantees.is_empty());
        }
    }
}
