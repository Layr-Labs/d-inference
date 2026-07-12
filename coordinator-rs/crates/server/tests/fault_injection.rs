use std::{
    collections::BTreeSet,
    fs,
    os::unix::process::ExitStatusExt as _,
    path::PathBuf,
    process::{Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
        mpsc,
    },
    time::Duration,
};

use axum::Router;
use darkbloom_coordinator_core::ids::Digest;
use darkbloom_coordinator_protocol::v2::{
    AttemptId, BinaryFrameFlags, BinaryFrameHeader, BinaryFrameKind, LeaseId, ProviderId,
    ProviderProcessGenerationId, RequestId as WireRequestId, ReservationId as WireReservationId,
    SessionEpoch, TerminalDisposition,
};
use darkbloom_coordinator_server::{
    crypto::{
        ReplayProofSigner, ReplayProofStore, ReplayStoreError, ReplayStoreLimits,
        TerminalDispositionStore, TerminalKey, TerminalRecord, TerminalResolution,
        TerminalStoreError,
    },
    database::{Database, DatabaseError},
    fault::{
        FaultAction, FaultControlError, FaultGuard, FaultOutcome, FaultPoint, arm,
        read_abort_marker, write_test_receipt, write_test_receipt_from_executions,
    },
    ledger::{
        AccountId, JobId, LedgerAmount, LedgerError, LedgerService, MutationDisposition, Operation,
        OperationKey, ReservationId, ReserveRequest,
    },
    ownership::{CoordinatorOwnership, OwnershipError},
    provider::{
        BinarySessionFrame, OutboundFrame, ProviderWriterConfig, SessionEvent,
        SessionEventSendError, SessionIdentity, WriterEnqueueError, provider_writer,
        session_event_channel,
    },
    request::{
        BytePipeLimits, CancellationReason, PipeCloseReason, PipeError, RequestCancellation,
        byte_pipe,
    },
    schema::SchemaError,
};
use sqlx::PgPool;
use tokio::{net::TcpListener, time::timeout};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

#[path = "fault_injection/durable.rs"]
mod durable;
#[path = "fault_injection/external.rs"]
mod external;
#[path = "fault_injection/lifecycle.rs"]
mod lifecycle;
#[path = "fault_injection/matrix.rs"]
mod matrix;
#[path = "fault_injection/postgres.rs"]
mod postgres;
#[path = "fault_injection/process.rs"]
mod process;
#[allow(dead_code, unused_imports)]
#[path = "postgres/support.rs"]
mod support;
#[path = "fault_injection/transport.rs"]
mod transport;

const REQUEST_DEADLINE_EPOCH_MILLIS: u64 = 4_102_444_800_000;

static FAULT_TEST_LOCK: Mutex<()> = Mutex::new(());

#[test]
fn synchronous_fault_hooks_reject_delay_plans() {
    let _serial = FAULT_TEST_LOCK
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    for point in [
        FaultPoint::PrepareSent,
        FaultPoint::PrepareReceived,
        FaultPoint::FirstChunk,
        FaultPoint::ProviderWriterSaturation,
        FaultPoint::BytePipeOverflow,
        FaultPoint::ReplayProofFsync,
        FaultPoint::TerminalCacheFsync,
    ] {
        assert!(matches!(
            arm(point, FaultAction::Delay),
            Err(FaultControlError::DelayUnsupported { point: rejected }) if rejected == point
        ));
    }
}

fn record_receipt(test_id: &str, guards: &[&FaultGuard], assertions: &[&str]) {
    write_test_receipt(test_id, guards, assertions).expect("write signed fault receipt");
}

fn terminal_record() -> TerminalRecord {
    TerminalRecord {
        key: TerminalKey {
            provider_id: ProviderId::new([1; 16]),
            provider_process_generation: ProviderProcessGenerationId::new([2; 16]),
            attempt_id: AttemptId::new([3; 16]),
        },
        terminal_digest: darkbloom_coordinator_protocol::v2::Digest::new([4; 32]),
        disposition: TerminalDisposition::Settled,
    }
}

fn temp_path(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!("darkbloom-{label}-{}", Uuid::new_v4()))
}
