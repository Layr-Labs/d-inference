//! The `FleetActor`: one nonblocking task owning all live fleet decision
//! state (plan §7.3, §11, §14).
//!
//! The actor owns (single-threaded inside the task — no locks):
//!
//! - the provider map keyed by stable `ProviderId`: current session epoch
//!   and [`SessionHandle`](crate::contracts::SessionHandle), trust state
//!   with monotonic `TrustEpoch` fencing (plan §9.1.6), the canonical
//!   revision-fenced `ProviderModelPresence` (plan §10.7), the latest
//!   advisory `CandidateSnapshot` from heartbeats, and per (provider, model)
//!   `HealthState` machines (plan §11.6);
//! - the fleet-wide `PermitBook` (plan §9.2.10, §11.3);
//! - the `CalibrationTable` per (model, hardware class) (plan §11.4).
//!
//! All decision logic is `darkbloom_core::fleet` — this module only owns the
//! mutable maps and reduces commands/observations into them. Mailbox
//! discipline follows plan §14: a reliable lifecycle/admission command lane
//! with strict priority over the coalesced heartbeat lane; admission fails
//! fast when the command lane is full (`FleetHandle::admit` uses `try_send`).
//!
//! # Permit identity
//!
//! The fleet MINTS every `PermitId` ([`permit_id_for`]) and carries it on
//! [`contracts::AdmitGrant::permit_id`](crate::contracts::AdmitGrant); the
//! request task echoes exactly that id in `FleetCommand::ReleasePermit`. No
//! other component derives permit ids.
//!
//! # Hedge budget (plan §11.8)
//!
//! The ONE global bounded prepare-hedge budget lives with the request tasks
//! (`request_task::shared_hedge_budget`) — that is where the hedge timer
//! fires and tokens are acquired/refunded. The fleet keeps NO hedge
//! accounting; it only enforces per-provider permits and lane headroom for
//! hedge dispatches like any other admission.
//!
//! Module layout: [`actor`] (the select loop), [`admit`] (the admission
//! operation), [`candidates`] (candidate assembly), [`permits`] (permit
//! minting/release), [`connect`] (connect/disconnect/supersede),
//! [`observe`] (health observations + heartbeats), [`state`] (the owned
//! maps), [`types`] (config/runtime/provider-state shapes).

mod actor;
mod admit;
mod candidates;
mod connect;
mod observe;
mod permits;
mod state;
mod types;

use darkbloom_core::fleet::permits::PermitBook;

pub use permits::permit_id_for;
pub use types::{FleetConfig, FleetRuntime, FleetTunables, TrustFloor};

pub(crate) use state::{
    HW_CLASS_CAPABILITY_PREFIX, SUPPORTS_MEDIA_CAPABILITY, SUPPORTS_TOOLS_CAPABILITY,
    SUPPORTS_VISION_CAPABILITY,
};
pub(crate) use types::{PermitMeta, PermitMetaMap, ProviderEntry, TrustState};

/// Spawns the single fleet actor task (plan §7.3: do not shard).
#[must_use]
pub fn spawn(cfg: FleetConfig) -> FleetRuntime {
    let FleetConfig {
        receivers,
        admission,
        catalog,
        cancel,
        tunables,
    } = cfg;
    let state = state::FleetState {
        providers: std::collections::HashMap::new(),
        permits: PermitBook::new(),
        permit_meta: std::collections::HashMap::new(),
        calibration: darkbloom_core::fleet::calibration::CalibrationTable::new(),
        admission,
        catalog,
        tunables,
        counters: state::FleetCounters::default(),
        admit_seq: 0,
    };
    let actor = actor::Actor::new(state, receivers, cancel.clone());
    let handle = tokio::spawn(actor.run());
    FleetRuntime { handle, cancel }
}
