//! Provider-session suites: real WebSocket sessions speaking v1/v2 wire
//! frames against `provider_session::serve`, plus the fleet actor driven
//! through its frozen mailbox contract.

mod fleet_actor;
mod v1;
mod v2;
