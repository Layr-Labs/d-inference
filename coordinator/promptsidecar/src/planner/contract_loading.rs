use super::{CacheAccess, PlanError, Planner};
use crate::artifacts::{self, LoadedArtifacts};
use crate::render;
use std::sync::Arc;
use std::time::Instant;

// The existing contract LRU also bounds compiled-template retention. There is
// no independent renderer map retaining evicted contracts or request values.
pub(super) struct LoadedContract {
    pub(super) artifacts: LoadedArtifacts,
    pub(super) templates: render::PreparedTemplates,
}

impl Planner {
    pub(super) fn load_contract(
        &self,
        contract_id: &str,
    ) -> Result<(Arc<LoadedContract>, CacheAccess), PlanError> {
        let metrics = self.metrics.clone();
        let root = self.artifact_root.clone();
        let loaded = self.cache.get_or_load(contract_id, || {
            let started = Instant::now();
            let result = artifacts::load(&root, contract_id, &self.tokenizers).map(|artifacts| {
                LoadedContract {
                    artifacts,
                    templates: render::PreparedTemplates::default(),
                }
            });
            metrics.cold_load_finished(started.elapsed(), result.is_ok());
            result
        });
        match loaded {
            Ok((contract, CacheAccess::Warm)) => {
                self.metrics.warm_load();
                Ok((contract, CacheAccess::Warm))
            }
            Ok((contract, CacheAccess::Waited)) => {
                self.metrics.load_wait();
                Ok((contract, CacheAccess::Waited))
            }
            Ok((contract, CacheAccess::Cold)) => Ok((contract, CacheAccess::Cold)),
            Err(_) => Err(PlanError::Contract),
        }
    }
}
