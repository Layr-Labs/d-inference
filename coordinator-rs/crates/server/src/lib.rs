//! Server library surface.

pub mod abort;
pub mod cancel;
pub mod chunk_pipe;
pub mod cli;
pub mod crypto_keys;
pub mod fleet_actor;
pub mod http;
pub mod ledger;
pub mod ledger_sql;
pub mod mock_provider;
pub mod provider_hub;
pub mod provider_session;
pub mod provider_ws;
pub mod recovery;
pub mod request_task;
pub mod sealed;
pub mod stream_billing;
pub mod telemetry;

pub use abort::{abort_frame, abort_losing_hedge, cancel_attempt, cancel_frame};
pub use cancel::{cancel_before_or_after_content, CancelOutcome};
pub use chunk_pipe::{bounded_chunk_pipe, ChunkPipe, ChunkPipeReader, PipeError, SequencedChunk};
pub use crypto_keys::CoordinatorKeys;
pub use fleet_actor::{spawn_fleet_actor, FleetError, FleetHandle};
pub use http::{router, AppState, ModelCard};
pub use ledger::{MemoryLedger, OperationKey, ReservationProvenance};
pub use provider_hub::{InboundReply, OutboundCmd, ProviderHub, SharedHub};
pub use provider_session::{spawn_session, Lane, ProviderSessionHandle, SessionError};
pub use recovery::{recover_undispatched, RecoveryAction};
pub use request_task::{spawn_request_task, ControlEvent, RequestTaskHandle};
pub use sealed::decrypt_request_body;
pub use stream_billing::{accept_pipe_chunk, billable_cap_from_checkpoint, pipe_and_checkpoint};
pub use telemetry::{bounded_telemetry, TelemetryEvent, TelemetrySink};

pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
