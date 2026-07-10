//! Server library surface.

pub mod fleet_actor;
pub mod http;
pub mod ledger;
pub mod provider_session;
pub mod provider_ws;

pub use fleet_actor::{spawn_fleet_actor, FleetError, FleetHandle};
pub use http::{router, AppState, ModelCard};
pub use ledger::{MemoryLedger, OperationKey, ReservationProvenance};
pub use provider_session::{spawn_session, Lane, ProviderSessionHandle, SessionError};

pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
