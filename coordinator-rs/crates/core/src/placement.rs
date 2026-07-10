//! Placement controller — declarative desired model state (plan §7.7).
//!
//! Does not queue customer requests. Publishes desired state versions that
//! providers reconcile via load/prefetch commands.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct PlacementVersion(pub u64);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DesiredModel {
    pub model_id: String,
    pub min_replicas: u32,
    pub target_replicas: u32,
}

#[derive(Debug, Default, Clone)]
pub struct PlacementController {
    version: PlacementVersion,
    desired: HashMap<String, DesiredModel>,
    /// Coalesced warm-demand signals per model.
    demand: HashMap<String, u64>,
}

impl PlacementController {
    pub fn signal_demand(&mut self, model_id: &str) {
        *self.demand.entry(model_id.to_string()).or_insert(0) += 1;
        let entry = self
            .desired
            .entry(model_id.to_string())
            .or_insert(DesiredModel {
                model_id: model_id.to_string(),
                min_replicas: 0,
                target_replicas: 0,
            });
        // Simple policy: any demand raises target to at least 1.
        if entry.target_replicas < 1 {
            entry.target_replicas = 1;
            entry.min_replicas = 1;
            self.version = PlacementVersion(self.version.0 + 1);
        }
    }

    pub fn version(&self) -> PlacementVersion {
        self.version
    }

    pub fn desired(&self) -> Vec<&DesiredModel> {
        self.desired.values().collect()
    }

    pub fn demand_for(&self, model_id: &str) -> u64 {
        self.demand.get(model_id).copied().unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn demand_bumps_version_and_target() {
        let mut c = PlacementController::default();
        assert_eq!(c.version(), PlacementVersion(0));
        c.signal_demand("m1");
        assert_eq!(c.version(), PlacementVersion(1));
        assert_eq!(c.desired()[0].target_replicas, 1);
        c.signal_demand("m1");
        // Already at 1 — version unchanged.
        assert_eq!(c.version(), PlacementVersion(1));
        assert_eq!(c.demand_for("m1"), 2);
    }
}
