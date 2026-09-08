//! Session connect/disconnect: epoch minting, atomic supersede, and
//! epoch-fenced teardown (plan §7.4, §9.1.1, §9.1.2).

use tokio::sync::oneshot;

use darkbloom_core::fleet::model_presence::ProviderModelPresence;
use darkbloom_core::ids::{ProviderId, SessionEpoch};

use crate::contracts::{
    session_channels, ConnectAccept, ConnectRejected, RegistrationSummary, SessionSeed,
};

use super::state::{hardware_class_from_capabilities, FleetState};

/// Mints the next session epoch for the stable identity and atomically
/// supersedes any prior session.
///
/// Fencing is by construction: the actor is the single epoch authority
/// (plan §9.1.1), epochs are monotonic per provider and never reused, and
/// the old epoch's [`crate::contracts::SessionHandle`] is dropped here — its
/// lanes close once outstanding grant clones drop, which the old session's
/// loops observe as the supersede signal. A later `Disconnect` from the old
/// epoch compares stale and cannot remove the new session (plan §9.1.2).
pub(crate) fn handle_connect(
    state: &mut FleetState,
    registration: RegistrationSummary,
    seed: SessionSeed,
    reply: oneshot::Sender<Result<ConnectAccept, ConnectRejected>>,
) {
    let provider = registration.provider;
    if !state.providers.contains_key(&provider)
        && state.providers.len() >= state.tunables.max_providers
    {
        let _ = reply.send(Err(ConnectRejected::Capacity));
        return;
    }

    let entry = state.providers.entry(provider).or_default();
    let epoch = entry.last_epoch.next();
    entry.last_epoch = epoch;

    let superseded = match entry.session.take() {
        Some(old) => {
            fence_session(&old);
            true
        }
        None => false,
    };
    // Presence and advisory state are per-session: the new provider process
    // mints its own revision domain, so the old high-water mark must not
    // fence its fresh (lower) revisions.
    entry.presence = ProviderModelPresence::new();
    entry.advisory = None;
    entry.hardware_class = hardware_class_from_capabilities(&registration.capabilities);

    let (handle, receivers) = session_channels(provider, epoch, seed.protocol, seed.lane_caps);
    entry.session = Some(handle.clone());
    entry.registration = Some(registration);

    tracing::info!(
        provider = %provider,
        epoch = epoch.get(),
        superseded,
        "provider session connected"
    );

    if reply
        .send(Ok(ConnectAccept {
            epoch,
            handle,
            receivers,
        }))
        .is_err()
    {
        // The session died between sending Connect and awaiting the reply:
        // it never ran, so its slot must not stay routable.
        clear_session(state, provider);
    }
}

/// Epoch-fenced disconnect: only the CURRENT epoch clears live state; a
/// stale epoch's teardown is ignored entirely (plan §9.1.2).
pub(crate) fn handle_disconnect(state: &mut FleetState, provider: ProviderId, epoch: SessionEpoch) {
    let Some(entry) = state.providers.get(&provider) else {
        state.counters.stale_commands += 1;
        return;
    };
    if epoch != entry.last_epoch || entry.session.is_none() {
        state.counters.stale_commands += 1;
        tracing::debug!(
            provider = %provider,
            stale_epoch = epoch.get(),
            current_epoch = entry.last_epoch.get(),
            "ignoring stale disconnect"
        );
        return;
    }
    clear_session(state, provider);
    tracing::info!(provider = %provider, epoch = epoch.get(), "provider session disconnected");
}

/// Sends the in-band fence sentinel on the superseded session's control
/// lane before its handle is dropped, so the old writer tears down
/// immediately instead of waiting for outstanding grant clones to drop.
/// Best-effort: a full/closed lane falls back to lane-closure fencing.
pub(crate) fn fence_session(old: &crate::contracts::SessionHandle) {
    let _ = old.submit_control(crate::contracts::ControlFrame::RawJson(
        bytes::Bytes::from_static(crate::provider_session::FENCE_FRAME),
    ));
}

/// Clears the live session, releases every outstanding permit for the
/// provider, and marks model presence unknown. Trust state, health machines,
/// and the epoch high-water mark survive (they are stable-identity state).
fn clear_session(state: &mut FleetState, provider: ProviderId) {
    if let Some(entry) = state.providers.get_mut(&provider) {
        entry.session = None;
        entry.presence = ProviderModelPresence::new();
        entry.advisory = None;
    }
    let stale: Vec<_> = state
        .permit_meta
        .iter()
        .filter(|(_, meta)| meta.provider == provider)
        .map(|(id, _)| *id)
        .collect();
    for permit in stale {
        state.permits.release(permit);
        state.permit_meta.remove(&permit);
    }
}
