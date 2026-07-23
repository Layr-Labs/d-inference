use super::{CacheAccess, Planner, Readiness};
use crate::preload::{
    PreloadError, PreloadReport, PreloadResult, PreloadStatus, validate_contracts,
};

impl Planner {
    /// Preloads an explicit active-contract set supplied by the coordinator.
    /// The list order is preserved to make cold-start IO deterministic.
    pub async fn preload_contracts(
        &self,
        contract_ids: Vec<String>,
    ) -> Result<PreloadReport, PreloadError> {
        validate_contracts(&contract_ids, self.cache.stats().capacity)?;
        let guard = self
            .preload_lock
            .clone()
            .try_lock_owned()
            .map_err(|_| PreloadError::AlreadyRunning)?;
        self.set_readiness(Readiness::Starting);
        self.run_preload(contract_ids, guard).await
    }

    async fn run_preload(
        &self,
        contract_ids: Vec<String>,
        _guard: tokio::sync::OwnedMutexGuard<()>,
    ) -> Result<PreloadReport, PreloadError> {
        self.metrics.preload_started(contract_ids.len());
        let all_permits = self
            .permits
            .clone()
            .acquire_many_owned(self.max_concurrency)
            .await
            .map_err(|_| PreloadError::Worker)?;
        let planner = self.clone();
        let report = tokio::task::spawn_blocking(move || {
            let _all_permits = all_permits;
            let results = contract_ids
                .into_iter()
                .map(|prompt_contract_id| {
                    let status = match planner.load_contract(&prompt_contract_id) {
                        Ok((_, CacheAccess::Cold)) => PreloadStatus::Cold,
                        Ok((_, CacheAccess::Warm | CacheAccess::Waited)) => PreloadStatus::Warm,
                        Err(_) => PreloadStatus::Failed,
                    };
                    PreloadResult {
                        prompt_contract_id,
                        status,
                    }
                })
                .collect();
            PreloadReport::from_results(results)
        })
        .await;
        match report {
            Ok(report) => {
                self.set_readiness(if report.ready {
                    Readiness::Ready
                } else {
                    Readiness::Degraded
                });
                self.metrics.preload_finished(report.ready);
                Ok(report)
            }
            Err(_) => {
                self.set_readiness(Readiness::Degraded);
                self.metrics.preload_finished(false);
                Err(PreloadError::Worker)
            }
        }
    }
}
