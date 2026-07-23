use crate::artifacts;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use thiserror::Error;

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PreloadRequest {
    pub prompt_contract_ids: Vec<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct PreloadReport {
    pub status: &'static str,
    pub ready: bool,
    pub requested: usize,
    pub warm: usize,
    pub cold: usize,
    pub failed: usize,
    pub results: Vec<PreloadResult>,
}

#[derive(Clone, Debug, Serialize)]
pub struct PreloadResult {
    pub prompt_contract_id: String,
    pub status: PreloadStatus,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PreloadStatus {
    Cold,
    Warm,
    Failed,
}

#[derive(Debug, Error)]
pub enum PreloadError {
    #[error("preload request is invalid")]
    InvalidRequest,
    #[error("preload request exceeds the loaded-contract bound")]
    TooManyContracts,
    #[error("a preload is already running")]
    AlreadyRunning,
    #[error("preload worker terminated")]
    Worker,
}

pub fn validate_contracts(contract_ids: &[String], maximum: usize) -> Result<(), PreloadError> {
    if contract_ids.is_empty() {
        return Err(PreloadError::InvalidRequest);
    }
    if contract_ids.len() > maximum {
        return Err(PreloadError::TooManyContracts);
    }
    let mut unique = HashSet::with_capacity(contract_ids.len());
    if contract_ids.iter().any(|contract_id| {
        !artifacts::is_valid_contract_id(contract_id) || !unique.insert(contract_id)
    }) {
        return Err(PreloadError::InvalidRequest);
    }
    Ok(())
}

impl PreloadReport {
    pub fn from_results(results: Vec<PreloadResult>) -> Self {
        let warm = count(&results, PreloadStatus::Warm);
        let cold = count(&results, PreloadStatus::Cold);
        let failed = count(&results, PreloadStatus::Failed);
        let ready = failed == 0 && !results.is_empty();
        Self {
            status: if ready { "ready" } else { "degraded" },
            ready,
            requested: results.len(),
            warm,
            cold,
            failed,
            results,
        }
    }
}

fn count(results: &[PreloadResult], status: PreloadStatus) -> usize {
    results
        .iter()
        .filter(|result| result.status == status)
        .count()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validation_is_bounded_unique_and_exact() {
        let valid = "a".repeat(64);
        assert!(validate_contracts(std::slice::from_ref(&valid), 1).is_ok());
        assert!(matches!(
            validate_contracts(&[valid.clone(), valid], 2),
            Err(PreloadError::InvalidRequest)
        ));
        assert!(matches!(
            validate_contracts(&["b".repeat(64), "c".repeat(64)], 1),
            Err(PreloadError::TooManyContracts)
        ));
        assert!(matches!(
            validate_contracts(&[], 1),
            Err(PreloadError::InvalidRequest)
        ));
    }
}
