//! The actor event loop (plan §14): a reliable command lane with strict
//! priority over the coalesced heartbeat lane, plus a periodic sweep for
//! permit expiry and mailbox-depth metrics.

use std::collections::HashMap;

use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use darkbloom_core::fleet::health::{self, HealthEvent};
use darkbloom_core::ids::ProviderId;

use crate::contracts::{FleetCommand, FleetReceivers, HeartbeatUpdate};

use super::state::{now_ms, FleetState};
use super::{admit, connect, observe};

pub(crate) struct Actor {
    state: FleetState,
    commands: mpsc::Receiver<FleetCommand>,
    heartbeats: mpsc::Receiver<HeartbeatUpdate>,
    cancel: CancellationToken,
}

impl Actor {
    pub(crate) fn new(
        state: FleetState,
        receivers: FleetReceivers,
        cancel: CancellationToken,
    ) -> Self {
        Self {
            state,
            commands: receivers.commands,
            heartbeats: receivers.heartbeats,
            cancel,
        }
    }

    pub(crate) async fn run(mut self) {
        let mut sweep = tokio::time::interval(self.state.tunables.sweep_interval);
        sweep.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            // `biased` keeps the reliable command lane strictly ahead of the
            // coalesced heartbeat lane whenever both are ready (plan §14).
            tokio::select! {
                biased;
                () = self.cancel.cancelled() => break,
                cmd = self.commands.recv() => match cmd {
                    Some(cmd) => self.handle_command(cmd),
                    // Every FleetHandle dropped: nothing can reach us again.
                    None => break,
                },
                update = self.heartbeats.recv() => match update {
                    Some(update) => self.handle_heartbeats(update),
                    None => break,
                },
                _ = sweep.tick() => self.sweep(),
            }
        }
        self.shutdown();
    }

    fn handle_command(&mut self, cmd: FleetCommand) {
        match cmd {
            FleetCommand::Admit { req, reply } => admit::handle_admit(&mut self.state, req, reply),
            FleetCommand::ReleasePermit { provider, permit } => {
                admit::handle_release(&mut self.state, provider, permit);
            }
            FleetCommand::Connect {
                registration,
                session_seed,
                reply,
            } => connect::handle_connect(&mut self.state, *registration, *session_seed, reply),
            FleetCommand::Disconnect { provider, epoch } => {
                connect::handle_disconnect(&mut self.state, provider, epoch);
            }
            FleetCommand::ModelLifecycle {
                provider,
                epoch,
                model,
                ready,
                revision,
            } => {
                observe::handle_lifecycle(&mut self.state, provider, epoch, model, ready, revision)
            }
            FleetCommand::TrustVerdict {
                provider,
                trust_epoch,
                verdict,
            } => observe::handle_trust(&mut self.state, provider, trust_epoch, verdict),
            FleetCommand::Observe(observation) => {
                observe::handle_observe(&mut self.state, observation);
            }
            FleetCommand::Snapshot { reply } => {
                let _ = reply.send(observe::snapshot(&self.state));
            }
        }
    }

    /// Applies one heartbeat, then drains and coalesces everything already
    /// queued (latest per provider wins) so a heartbeat burst costs one pass.
    fn handle_heartbeats(&mut self, first: HeartbeatUpdate) {
        let mut latest: HashMap<ProviderId, HeartbeatUpdate> = HashMap::new();
        latest.insert(first.provider, first);
        while let Ok(update) = self.heartbeats.try_recv() {
            latest.insert(update.provider, update);
        }
        for (_, update) in latest {
            observe::handle_heartbeat(&mut self.state, update);
        }
    }

    /// Permit hard-expiry sweep (plan §9.2.10) plus mailbox-depth metrics.
    fn sweep(&mut self) {
        let now = now_ms();
        let expired = self.state.permits.expire(now);
        for permit in expired {
            let Some(meta) = self.state.permit_meta.remove(&permit) else {
                continue;
            };
            tracing::debug!(
                provider = %meta.provider,
                model = %meta.model,
                probe = meta.is_probe,
                "prepare permit expired"
            );
            // A probe permit that expired without any observation failed its
            // probe: the pair returns to quarantine (plan §11.6).
            if meta.is_probe {
                if let Some(entry) = self.state.providers.get_mut(&meta.provider) {
                    let current = entry.health.get(&meta.model).copied().unwrap_or_default();
                    if let Ok(next) = health::apply(
                        current,
                        HealthEvent::ProbeFailed,
                        now,
                        &self.state.tunables.health,
                    ) {
                        entry.health.insert(meta.model.clone(), next);
                    }
                }
            }
        }

        tracing::debug!(
            target: "darkbloom::fleet::metrics",
            command_depth = self.commands.len(),
            heartbeat_depth = self.heartbeats.len(),
            providers = self.state.providers.len(),
            permits_outstanding = self.state.permits.total_outstanding(),
            hedge_tokens = self.state.hedge.available(),
            admits_granted = self.state.counters.admits_granted,
            admits_retry = self.state.counters.admits_retry,
            admits_rejected = self.state.counters.admits_rejected,
            "fleet actor depth gauges"
        );
    }

    /// Fences every live session (in-band sentinel, then handle drop) so
    /// sessions tear down promptly — see `provider_session` module docs.
    fn shutdown(mut self) {
        for (provider, entry) in self.state.providers.iter_mut() {
            if let Some(old) = entry.session.take() {
                super::connect::fence_session(&old);
                tracing::debug!(provider = %provider, "fleet shutdown: fencing session");
            }
        }
        tracing::info!(
            providers = self.state.providers.len(),
            "fleet actor stopped"
        );
    }
}
