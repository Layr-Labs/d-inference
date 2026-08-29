//! Canonical model presence per provider (plan section 10.7).
//!
//! One enum, reduced from versioned `model_ready`/`model_gone` lifecycle
//! events and full heartbeat snapshots, replaces the Go coordinator's four
//! overlapping views (`WarmModels`, `CurrentModel`, synthetic slots, and
//! pending-load state).
//!
//! Both event kinds carry one monotonically increasing provider-process
//! [`StateRevision`]. The reducer ignores anything at or below the current
//! high-water mark, so a delayed heartbeat cannot resurrect a model after
//! `model_gone` or overwrite a newer ready generation.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::ids::{ModelId, StateRevision};

/// Presence of one model on one provider.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ModelPresence {
    /// Not resident. The default for any model never mentioned.
    #[default]
    NotPresent,
    /// Load in progress (heartbeat-reported). Not routable.
    Loading,
    /// Resident and ready — the only routable presence.
    Ready,
}

impl ModelPresence {
    /// Only `Ready` satisfies the concrete model-readiness hard gate
    /// (plan section 11.2).
    #[must_use]
    pub fn is_routable(self) -> bool {
        matches!(self, Self::Ready)
    }
}

/// Presence events, each fenced by the provider-process state revision.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PresenceEvent {
    /// Versioned lifecycle event: the model became ready.
    ModelReady {
        revision: StateRevision,
        model: ModelId,
    },
    /// Versioned lifecycle event: the model is gone.
    ModelGone {
        revision: StateRevision,
        model: ModelId,
    },
    /// Full heartbeat snapshot. Reconciles missed events by replacing the
    /// entire per-provider view (models absent from the snapshot become
    /// `NotPresent`).
    HeartbeatSnapshot {
        revision: StateRevision,
        models: BTreeMap<ModelId, ModelPresence>,
    },
}

impl PresenceEvent {
    fn revision(&self) -> StateRevision {
        match self {
            Self::ModelReady { revision, .. }
            | Self::ModelGone { revision, .. }
            | Self::HeartbeatSnapshot { revision, .. } => *revision,
        }
    }
}

/// Whether an event mutated the view or was fenced as stale.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PresenceOutcome {
    Applied,
    /// Event revision at or below the high-water mark: ignored entirely
    /// (plan section 10.7).
    IgnoredStale,
}

/// The canonical per-provider model-presence view.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ProviderModelPresence {
    revision: StateRevision,
    models: BTreeMap<ModelId, ModelPresence>,
}

impl ProviderModelPresence {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Reduce one event. Monotonic: an event must carry a revision strictly
    /// above the high-water mark to have any effect.
    pub fn apply(&mut self, event: PresenceEvent) -> PresenceOutcome {
        if event.revision() <= self.revision {
            return PresenceOutcome::IgnoredStale;
        }
        self.revision = event.revision();
        match event {
            PresenceEvent::ModelReady { model, .. } => {
                self.models.insert(model, ModelPresence::Ready);
            }
            PresenceEvent::ModelGone { model, .. } => {
                self.models.remove(&model);
            }
            PresenceEvent::HeartbeatSnapshot { models, .. } => {
                self.models = models
                    .into_iter()
                    .filter(|(_, presence)| *presence != ModelPresence::NotPresent)
                    .collect();
            }
        }
        PresenceOutcome::Applied
    }

    /// Current presence for a model; `NotPresent` when never mentioned.
    #[must_use]
    pub fn presence(&self, model: &ModelId) -> ModelPresence {
        self.models.get(model).copied().unwrap_or_default()
    }

    #[must_use]
    pub fn revision(&self) -> StateRevision {
        self.revision
    }

    /// Models currently `Ready` (the candidate-index feed).
    pub fn ready_models(&self) -> impl Iterator<Item = &ModelId> {
        self.models
            .iter()
            .filter(|(_, p)| p.is_routable())
            .map(|(m, _)| m)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn model(name: &str) -> ModelId {
        ModelId::new(name)
    }

    fn rev(n: u64) -> StateRevision {
        StateRevision::new(n)
    }

    #[test]
    fn stale_heartbeat_cannot_resurrect_gone_model() {
        let mut view = ProviderModelPresence::new();
        assert_eq!(
            view.apply(PresenceEvent::ModelReady {
                revision: rev(1),
                model: model("qwen"),
            }),
            PresenceOutcome::Applied
        );
        assert_eq!(
            view.apply(PresenceEvent::ModelGone {
                revision: rev(3),
                model: model("qwen"),
            }),
            PresenceOutcome::Applied
        );
        // A delayed heartbeat from revision 2 claims the model is ready.
        let stale = PresenceEvent::HeartbeatSnapshot {
            revision: rev(2),
            models: BTreeMap::from([(model("qwen"), ModelPresence::Ready)]),
        };
        assert_eq!(view.apply(stale), PresenceOutcome::IgnoredStale);
        assert_eq!(view.presence(&model("qwen")), ModelPresence::NotPresent);
    }

    #[test]
    fn equal_revision_is_stale() {
        let mut view = ProviderModelPresence::new();
        view.apply(PresenceEvent::ModelReady {
            revision: rev(5),
            model: model("a"),
        });
        assert_eq!(
            view.apply(PresenceEvent::ModelGone {
                revision: rev(5),
                model: model("a"),
            }),
            PresenceOutcome::IgnoredStale
        );
        assert_eq!(view.presence(&model("a")), ModelPresence::Ready);
    }

    #[test]
    fn snapshot_replaces_whole_view() {
        let mut view = ProviderModelPresence::new();
        view.apply(PresenceEvent::ModelReady {
            revision: rev(1),
            model: model("a"),
        });
        view.apply(PresenceEvent::HeartbeatSnapshot {
            revision: rev(2),
            models: BTreeMap::from([(model("b"), ModelPresence::Loading)]),
        });
        assert_eq!(view.presence(&model("a")), ModelPresence::NotPresent);
        assert_eq!(view.presence(&model("b")), ModelPresence::Loading);
        assert!(!view.presence(&model("b")).is_routable());
        assert_eq!(view.ready_models().count(), 0);
    }
}
