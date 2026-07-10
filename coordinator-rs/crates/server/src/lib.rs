//! Server library surface.

pub mod abort;
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
pub mod request_task;
pub mod sealed;
pub mod telemetry;

pub use abort::{abort_frame, abort_losing_hedge};
pub use chunk_pipe::{bounded_chunk_pipe, ChunkPipe, PipeError};
pub use crypto_keys::CoordinatorKeys;
pub use fleet_actor::{spawn_fleet_actor, FleetError, FleetHandle};
pub use http::{router, AppState, ModelCard};
pub use ledger::{MemoryLedger, OperationKey, ReservationProvenance};
pub use provider_hub::{InboundReply, OutboundCmd, ProviderHub, SharedHub};
pub use provider_session::{spawn_session, Lane, ProviderSessionHandle, SessionError};
pub use request_task::{spawn_request_task, ControlEvent, RequestTaskHandle};
pub use sealed::decrypt_request_body;
pub use telemetry::{bounded_telemetry, TelemetryEvent, TelemetrySink};

pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
