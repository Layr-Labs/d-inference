//! Server library surface.

pub mod fleet_actor;
pub mod http;

pub use fleet_actor::{spawn_fleet_actor, FleetError, FleetHandle};
pub use http::{router, AppState, ModelCard};

pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
