//! Server library surface.

pub mod abort;
pub mod cancel;
pub mod chunk_pipe;
pub mod cli;
pub mod crypto_keys;
pub mod deposits;
pub mod external_events;
pub mod fleet_actor;
pub mod http;
pub mod ledger;
pub mod ledger_sql;
pub mod mock_provider;
pub mod outbox;
pub mod ownership;
pub mod provider_hub;
pub mod provider_session;
pub mod provider_ws;
pub mod recovery;
pub mod request_task;
pub mod sealed;
pub mod stream_billing;
pub mod telemetry;
pub mod terminal_ingest;
pub mod terminal_validate;

pub use abort::{abort_frame, abort_losing_hedge, cancel_attempt, cancel_frame};
pub use cancel::{cancel_before_or_after_content, CancelOutcome};
pub use chunk_pipe::{bounded_chunk_pipe, ChunkPipe, ChunkPipeReader, PipeError, SequencedChunk};
pub use crypto_keys::CoordinatorKeys;
pub use deposits::{apply_stripe_deposit, deposit_payload_digest, deposit_sql, DepositError};
pub use external_events::{
    forget_sql as external_event_forget_sql, observe_sql as external_event_observe_sql,
    ExternalEventInbox,
};
pub use fleet_actor::{spawn_fleet_actor, FleetError, FleetHandle};
pub use http::{router, AppState, ModelCard};
pub use ledger::{LedgerError, MemoryLedger, OperationKey, ReservationProvenance};
pub use outbox::{ack_done_sql, requeue_sql, Outbox, OutboxEntry, OutboxError};
pub use ownership::{
    acquire_sql as ownership_acquire_sql, heartbeat_sql as ownership_heartbeat_sql,
    release_sql as ownership_release_sql, run_ownership_heartbeat, Epoch, Gate as OwnershipGate,
    LocalOwnershipStore, OwnershipError,
};
pub use provider_hub::{InboundReply, OutboundCmd, ProviderHub, SharedHub, StartResult};
pub use provider_session::{spawn_session, Lane, ProviderSessionHandle, SessionError};
pub use recovery::{
    classify_held_job, force_settle_held, force_settle_held_fenced, recover_start_authorized_held,
    recover_undispatched, recover_undispatched_fenced, RecoveryAction,
};
pub use request_task::{spawn_request_task, ControlEvent, RequestTaskHandle};
pub use sealed::decrypt_request_body;
pub use stream_billing::{
    accept_pipe_chunk, billable_cap_from_checkpoint, billable_cap_micro_usd, pipe_and_checkpoint,
    stream_billable_tokens,
};
pub use telemetry::{bounded_telemetry, TelemetryEvent, TelemetrySink};
pub use terminal_ingest::{
    ingest_terminal, lookup_sql, record_late_sql, MemoryTerminalStore, TerminalDisposition,
    TerminalIngest, TerminalIngestError,
};
pub use terminal_validate::validate_provider_terminal;

pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
