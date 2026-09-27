use super::readiness::PreloadOperation;
use super::{CacheAccess, Planner};
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
        let operation = PreloadOperation::begin(
            self.readiness.clone(),
            self.metrics.clone(),
            contract_ids.len(),
        )?;
        self.run_preload(contract_ids, guard, operation).await
    }

    async fn run_preload(
        &self,
        contract_ids: Vec<String>,
        guard: tokio::sync::OwnedMutexGuard<()>,
        operation: PreloadOperation,
    ) -> Result<PreloadReport, PreloadError> {
        #[cfg(test)]
        self.test_hooks.before_preload_permits();
        let all_permits = self
            .permits
            .clone()
            .acquire_many_owned(self.max_concurrency)
            .await
            .map_err(|_| PreloadError::Worker)?;
        let planner = self.clone();
        let joined = tokio::task::spawn_blocking(move || {
            let results = contract_ids
                .into_iter()
                .map(|prompt_contract_id| {
                    #[cfg(test)]
                    planner.test_hooks.before_preload_load(&prompt_contract_id);
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
            // Keep BOTH the mutex and all worker permits through blocking work
            // and publication after join. Cancellation cannot release either
            // early; an unobserved task result drops them only when work ends.
            (PreloadReport::from_results(results), guard, all_permits)
        })
        .await;
        let (report, guard, all_permits) = joined.map_err(|_| PreloadError::Worker)?;
        operation.finish(&report);
        drop(all_permits);
        drop(guard);
        Ok(report)
    }
}
