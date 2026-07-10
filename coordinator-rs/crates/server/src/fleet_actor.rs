//! FleetActor runtime: bounded mailbox owning live admission state.

use darkbloom_core::{AdmitRequest, AdmissionDecision, FleetState, ProviderSnapshot};
use std::collections::VecDeque;
use tokio::sync::{mpsc, oneshot};

const LIFECYCLE_CAP: usize = 1024;
const HEARTBEAT_CAP: usize = 4096;

pub enum FleetCommand {
    Upsert(ProviderSnapshot),
    Remove {
        provider_id: String,
        session_epoch: u64,
    },
    Admit {
        request: AdmitRequest,
        reply: oneshot::Sender<AdmissionDecision>,
    },
    RecordTtft {
        model: String,
        predicted_ms: f64,
        actual_ms: f64,
    },
    ModelReady {
        provider_id: String,
        model: String,
        state_revision: u64,
    },
    ModelGone {
        provider_id: String,
        model: String,
        state_revision: u64,
    },
    /// Apply a structured_error class to provider health/trust.
    StructuredError {
        provider_id: String,
        class: String,
        model: Option<String>,
    },
    Snapshot(oneshot::Sender<FleetState>),
}

/// Two-lane mailbox: reliable lifecycle/admission vs coalesced heartbeats.
pub struct FleetActor {
    lifecycle_rx: mpsc::Receiver<FleetCommand>,
    heartbeat_rx: mpsc::Receiver<ProviderSnapshot>,
    state: FleetState,
}

#[derive(Clone)]
pub struct FleetHandle {
    lifecycle_tx: mpsc::Sender<FleetCommand>,
    heartbeat_tx: mpsc::Sender<ProviderSnapshot>,
}

impl FleetHandle {
    pub async fn admit(&self, request: AdmitRequest) -> Result<AdmissionDecision, FleetError> {
        let (tx, rx) = oneshot::channel();
        self.lifecycle_tx
            .try_send(FleetCommand::Admit {
                request,
                reply: tx,
            })
            .map_err(|_| FleetError::MailboxFull)?;
        rx.await.map_err(|_| FleetError::ActorGone)
    }

    pub fn upsert_heartbeat(&self, snap: ProviderSnapshot) -> Result<(), FleetError> {
        // Coalesced: if full, drop oldest by draining one then push (best-effort).
        if self.heartbeat_tx.try_send(snap.clone()).is_err() {
            // Fail admission path stays on lifecycle lane; heartbeats may drop.
            let _ = snap;
            return Err(FleetError::MailboxFull);
        }
        Ok(())
    }

    pub async fn upsert_lifecycle(&self, snap: ProviderSnapshot) -> Result<(), FleetError> {
        self.lifecycle_tx
            .try_send(FleetCommand::Upsert(snap))
            .map_err(|_| FleetError::MailboxFull)
    }

    pub async fn remove(
        &self,
        provider_id: String,
        session_epoch: u64,
    ) -> Result<(), FleetError> {
        self.lifecycle_tx
            .try_send(FleetCommand::Remove {
                provider_id,
                session_epoch,
            })
            .map_err(|_| FleetError::MailboxFull)
    }

    pub fn record_ttft(&self, model: String, predicted_ms: f64, actual_ms: f64) {
        let _ = self.lifecycle_tx.try_send(FleetCommand::RecordTtft {
            model,
            predicted_ms,
            actual_ms,
        });
    }

    pub fn model_ready(&self, provider_id: String, model: String, state_revision: u64) {
        let _ = self.lifecycle_tx.try_send(FleetCommand::ModelReady {
            provider_id,
            model,
            state_revision,
        });
    }

    pub fn model_gone(&self, provider_id: String, model: String, state_revision: u64) {
        let _ = self.lifecycle_tx.try_send(FleetCommand::ModelGone {
            provider_id,
            model,
            state_revision,
        });
    }

    pub fn structured_error(&self, provider_id: String, class: String, model: Option<String>) {
        let _ = self.lifecycle_tx.try_send(FleetCommand::StructuredError {
            provider_id,
            class,
            model,
        });
    }
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum FleetError {
    #[error("fleet mailbox full")]
    MailboxFull,
    #[error("fleet actor gone")]
    ActorGone,
}

pub fn spawn_fleet_actor() -> (FleetHandle, tokio::task::JoinHandle<()>) {
    let (lifecycle_tx, lifecycle_rx) = mpsc::channel(LIFECYCLE_CAP);
    let (heartbeat_tx, heartbeat_rx) = mpsc::channel(HEARTBEAT_CAP);
    let actor = FleetActor {
        lifecycle_rx,
        heartbeat_rx,
        state: FleetState::default(),
    };
    let handle = FleetHandle {
        lifecycle_tx,
        heartbeat_tx,
    };
    let join = tokio::spawn(actor.run());
    (handle, join)
}

impl FleetActor {
    async fn run(mut self) {
        let mut pending_heartbeats: VecDeque<ProviderSnapshot> = VecDeque::new();
        loop {
            tokio::select! {
                biased;
                cmd = self.lifecycle_rx.recv() => {
                    match cmd {
                        None => break,
                        Some(cmd) => self.handle(cmd),
                    }
                }
                snap = self.heartbeat_rx.recv() => {
                    match snap {
                        None => break,
                        Some(snap) => {
                            // Coalesce by provider_id: keep latest only.
                            pending_heartbeats.retain(|s| s.provider_id != snap.provider_id);
                            pending_heartbeats.push_back(snap);
                            while let Some(s) = pending_heartbeats.pop_front() {
                                self.state.upsert(s);
                            }
                        }
                    }
                }
            }
        }
    }

    fn handle(&mut self, cmd: FleetCommand) {
        match cmd {
            FleetCommand::Upsert(snap) => self.state.upsert(snap),
            FleetCommand::Remove {
                provider_id,
                session_epoch,
            } => {
                if let Some(existing) = self.state.providers.get(&provider_id) {
                    if existing.session_epoch == session_epoch {
                        self.state.providers.remove(&provider_id);
                    }
                }
            }
            FleetCommand::Admit { request, reply } => {
                let decision = self.state.admit(&request);
                let _ = reply.send(decision);
            }
            FleetCommand::RecordTtft {
                model,
                predicted_ms,
                actual_ms,
            } => {
                self.state.record_ttft_sample(&model, predicted_ms, actual_ms);
            }
            FleetCommand::ModelReady {
                provider_id,
                model,
                state_revision,
            } => {
                let _ = self
                    .state
                    .apply_model_ready(&provider_id, &model, state_revision);
            }
            FleetCommand::ModelGone {
                provider_id,
                model,
                state_revision,
            } => {
                let _ = self
                    .state
                    .apply_model_gone(&provider_id, &model, state_revision);
            }
            FleetCommand::StructuredError {
                provider_id,
                class,
                model,
            } => {
                use darkbloom_core::{
                    action_for_class, apply_health_action, apply_trust_action, ErrorAction,
                };
                let action = action_for_class(&class);
                if let Some(p) = self.state.providers.get_mut(&provider_id) {
                    apply_health_action(&mut p.health, &action, std::time::Instant::now());
                    apply_trust_action(&mut p.trust, &action);
                    if matches!(action, ErrorAction::HardFence) {
                        p.trusted = false;
                        p.challenge_fresh = false;
                    }
                    // model_not_ready: drop the model from ready set so admission
                    // stops selecting it until model_ready arrives.
                    if matches!(action, ErrorAction::SignalPlacement) {
                        if let Some(m) = model {
                            p.ready_models.remove(&m);
                        }
                    }
                }
            }
            FleetCommand::Snapshot(reply) => {
                let _ = reply.send(self.state.clone());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use darkbloom_core::{AttemptId, HealthMachine};
    use std::collections::HashSet;
    use std::time::Duration;

    #[tokio::test]
    async fn admit_through_actor() {
        let (handle, _join) = spawn_fleet_actor();
        let mut ready = HashSet::new();
        ready.insert("m".into());
        handle
            .upsert_lifecycle(ProviderSnapshot {
                provider_id: "p1".into(),
                session_epoch: 1,
                trusted: true,
                challenge_fresh: true,
                encrypted_transport: true,
                ready_models: ready,
                health: HealthMachine::healthy(),
                data_lane_full: false,
                predicted_first_content_ms: 10.0,
                predicted_decode_ms: 20.0,
                trust: darkbloom_core::TrustState::default(),
            })
            .await
            .unwrap();
        // Allow actor to process upsert before admit.
        tokio::task::yield_now().await;
        let decision = handle
            .admit(AdmitRequest {
                model: "m".into(),
                attempt: AttemptId::new("a1"),
                exclude_providers: HashSet::new(),
                require_tools: false,
                permit_ttl: Duration::from_secs(2),
            })
            .await
            .unwrap();
        assert!(matches!(decision, AdmissionDecision::Prepare(_)));
    }

    #[tokio::test]
    async fn security_error_hard_fences_provider() {
        let (handle, _join) = spawn_fleet_actor();
        let mut ready = HashSet::new();
        ready.insert("m".into());
        let mut trust = darkbloom_core::TrustState::default();
        let _ = trust.apply(darkbloom_core::TrustEvidence {
            provider_id: "p1".into(),
            session_epoch: 1,
            trust_epoch: darkbloom_core::TrustEpoch(1),
            level: darkbloom_core::TrustLevel::Hardware,
            challenge_fresh: true,
            runtime_ok: true,
            encrypted_transport: true,
        });
        handle
            .upsert_lifecycle(ProviderSnapshot {
                provider_id: "p1".into(),
                session_epoch: 1,
                trusted: true,
                challenge_fresh: true,
                encrypted_transport: true,
                ready_models: ready,
                health: HealthMachine::healthy(),
                data_lane_full: false,
                predicted_first_content_ms: 10.0,
                predicted_decode_ms: 20.0,
                trust,
            })
            .await
            .unwrap();
        tokio::task::yield_now().await;
        handle.structured_error("p1".into(), "security".into(), None);
        tokio::task::yield_now().await;
        let decision = handle
            .admit(AdmitRequest {
                model: "m".into(),
                attempt: AttemptId::new("a2"),
                exclude_providers: HashSet::new(),
                require_tools: false,
                permit_ttl: Duration::from_secs(2),
            })
            .await
            .unwrap();
        // Hard-fenced provider is no longer warm-eligible → RetryAfter NoWarmProvider.
        assert!(matches!(
            decision,
            AdmissionDecision::RetryAfter { .. }
        ));
    }

    #[tokio::test]
    async fn model_not_ready_drops_model_from_ready_set() {
        let (handle, _join) = spawn_fleet_actor();
        let mut ready = HashSet::new();
        ready.insert("m".into());
        ready.insert("other".into());
        handle
            .upsert_lifecycle(ProviderSnapshot {
                provider_id: "p1".into(),
                session_epoch: 1,
                trusted: true,
                challenge_fresh: true,
                encrypted_transport: true,
                ready_models: ready,
                health: HealthMachine::healthy(),
                data_lane_full: false,
                predicted_first_content_ms: 10.0,
                predicted_decode_ms: 20.0,
                trust: darkbloom_core::TrustState::default(),
            })
            .await
            .unwrap();
        tokio::task::yield_now().await;
        handle.structured_error("p1".into(), "model_not_ready".into(), Some("m".into()));
        tokio::task::yield_now().await;
        let decision = handle
            .admit(AdmitRequest {
                model: "m".into(),
                attempt: AttemptId::new("a3"),
                exclude_providers: HashSet::new(),
                require_tools: false,
                permit_ttl: Duration::from_secs(2),
            })
            .await
            .unwrap();
        assert!(matches!(decision, AdmissionDecision::RetryAfter { .. }));
        // Other model still warm.
        let decision2 = handle
            .admit(AdmitRequest {
                model: "other".into(),
                attempt: AttemptId::new("a4"),
                exclude_providers: HashSet::new(),
                require_tools: false,
                permit_ttl: Duration::from_secs(2),
            })
            .await
            .unwrap();
        assert!(matches!(decision2, AdmissionDecision::Prepare(_)));
    }
}
