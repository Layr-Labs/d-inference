//! Inter-component contracts: every seam between the server components
//! (plan §7) — the fleet mailbox, the provider-session handle and writer
//! lanes, the per-attempt event sinks, the bounded consumer byte pipe, the
//! ledger facade, and the shared application state.
//!
//! These types were frozen during parallel component development; the
//! integration phase unfroze them and folded the reported seam gaps back in
//! (permit identity on [`AdmitGrant`], the grant-carried provider key,
//! per-MTok pricing on [`PriceCard`], the payout rate on [`RequestPolicy`],
//! and real fencing identifiers on the ledger parameter structs).
//!
//! Entry-point conventions (implemented by the owning modules):
//!
//! - `fleet::spawn(FleetConfig) -> FleetRuntime` — consumes the receivers
//!   created by [`fleet_channels`], returns join handles.
//! - `http::build_router(AppState) -> axum::Router` — all consumer routes.
//! - `provider_session::serve(socket, SessionDeps)` — one connection.
//! - `request_task::run(RequestTaskDeps, NormalizedRequest)` — one request.
//!
//! Every contract type is re-exported flat from this module: callers (and
//! the integration tests) address `crate::contracts::X` /
//! `darkbloom_server::contracts::X` regardless of which sibling owns it.

mod chunks;
mod fleet;
mod ledger;
mod policy;
mod session;
mod state;

pub use chunks::{chunk_pipe, ChunkFrame, ChunkReceiver, ChunkSender, PipeError};
pub use fleet::{
    fleet_channels, AdmitGrant, AdmitOutcome, AdmitRequest, ConnectAccept, ConnectRejected,
    FleetCommand, FleetHandle, FleetObservation, FleetReceivers, FleetSnapshot, FleetUnavailable,
    HeartbeatUpdate, RegistrationSummary, SessionSeed, TrustVerdict,
};
pub use ledger::{
    LedgerError, LedgerFacade, ReleaseParams, ReserveOutcome, ReserveParams, ResizeFreezeParams,
    SettleOutcome, SettleParams,
};
pub use policy::{CatalogSnapshot, PriceCard, RequestPolicy, SharedCatalog};
pub use session::{
    session_channels, AttemptEvent, AttemptSinks, AttemptSinksHandle, ControlFrame, DataFrame,
    OnWire, ProtocolGen, SessionCommand, SessionHandle, SessionLaneCaps, SessionReceivers,
    SubmitError, WriteError,
};
pub use state::{ApiKeyRecord, ApiKeyStore, AppState, CoordinatorKeys};
