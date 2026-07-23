use crate::api::{BlockBoundary, PlanRequest, PlanResponse};
use crate::artifact_cache::{CacheAccess, SingleflightLru};
use crate::artifacts::{self, LoadedArtifacts};
use crate::contract::BLOCK_SIZE;
use crate::endpoint;
use crate::hash;
use crate::metrics::{Metrics, MetricsSnapshot};
use crate::normalize;
use crate::render;
use serde::Serialize;
use serde_json::Value;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU8, Ordering};
use std::time::Instant;
use thiserror::Error;
use tokio::sync::{Mutex, OwnedSemaphorePermit, Semaphore};

mod preloading;

#[derive(Clone)]
pub struct Planner {
    artifact_root: Arc<PathBuf>,
    cache: Arc<SingleflightLru<LoadedArtifacts, artifacts::ArtifactError>>,
    permits: Arc<Semaphore>,
    preload_lock: Arc<Mutex<()>>,
    readiness: Arc<AtomicU8>,
    metrics: Arc<Metrics>,
    max_concurrency: u32,
    max_tokens: usize,
}

struct Planned {
    response: PlanResponse,
    token_ids: Vec<u32>,
    template_input: Value,
    provider_body: Value,
}

#[derive(Debug, Error)]
pub enum PlanError {
    #[error("planner is not ready")]
    NotReady,
    #[error("planner is at capacity")]
    AtCapacity,
    #[error("request scope is invalid")]
    InvalidScope,
    #[error("prompt contract could not be loaded")]
    Contract,
    #[error("request endpoint could not be lowered")]
    Endpoint,
    #[error("request could not be normalized")]
    Normalize,
    #[error("chat template could not be rendered: {0}")]
    Render(#[source] render::RenderError),
    #[error("prompt could not be tokenized")]
    Tokenize,
    #[error("prompt token count exceeded its bound")]
    TooManyTokens,
    #[error("block chain could not be computed")]
    BlockHash,
    #[error("planner worker terminated")]
    Worker,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum Readiness {
    Starting = 0,
    Ready = 1,
    Degraded = 2,
}

#[derive(Debug, Serialize)]
pub struct PlannerStatus {
    pub status: &'static str,
    pub ready: bool,
    pub loaded_contracts: usize,
    pub loading_contracts: usize,
    pub max_loaded_contracts: usize,
    pub planning_permits_available: usize,
    pub max_planning_concurrency: u32,
    pub metrics: MetricsSnapshot,
}

impl Planner {
    pub fn new(
        artifact_root: PathBuf,
        max_concurrency: usize,
        max_loaded_contracts: usize,
        max_tokens: usize,
    ) -> Self {
        let max_concurrency = max_concurrency.max(1).min(u32::MAX as usize);
        let max_concurrency_u32 = u32::try_from(max_concurrency).unwrap_or(u32::MAX);
        Self {
            artifact_root: Arc::new(artifact_root),
            cache: Arc::new(SingleflightLru::new(max_loaded_contracts)),
            permits: Arc::new(Semaphore::new(max_concurrency)),
            preload_lock: Arc::new(Mutex::new(())),
            readiness: Arc::new(AtomicU8::new(Readiness::Ready as u8)),
            metrics: Arc::new(Metrics::default()),
            max_concurrency: max_concurrency_u32,
            max_tokens,
        }
    }

    pub fn mark_starting(&self) {
        self.set_readiness(Readiness::Starting);
    }

    pub fn readiness(&self) -> Readiness {
        match self.readiness.load(Ordering::Acquire) {
            value if value == Readiness::Ready as u8 => Readiness::Ready,
            value if value == Readiness::Degraded as u8 => Readiness::Degraded,
            _ => Readiness::Starting,
        }
    }

    pub fn status(&self) -> PlannerStatus {
        let readiness = self.readiness();
        let cache = self.cache.stats();
        PlannerStatus {
            status: match readiness {
                Readiness::Starting => "starting",
                Readiness::Ready => "ok",
                Readiness::Degraded => "degraded",
            },
            ready: readiness == Readiness::Ready,
            loaded_contracts: cache.loaded,
            loading_contracts: cache.loading,
            max_loaded_contracts: cache.capacity,
            planning_permits_available: self.permits.available_permits(),
            max_planning_concurrency: self.max_concurrency,
            metrics: self.metrics.snapshot(),
        }
    }

    pub fn record_timeout(&self, elapsed: std::time::Duration) {
        self.metrics.plan_timed_out(elapsed);
    }

    fn set_readiness(&self, readiness: Readiness) {
        self.readiness.store(readiness as u8, Ordering::Release);
    }

    pub async fn plan(&self, request: PlanRequest) -> Result<PlanResponse, PlanError> {
        Ok(self.plan_with_tokens(request).await?.response)
    }

    pub async fn fixture_plan(
        &self,
        request: PlanRequest,
    ) -> Result<(PlanResponse, Vec<u32>, Value, Value), PlanError> {
        let planned = self.plan_with_tokens(request).await?;
        Ok((
            planned.response,
            planned.token_ids,
            planned.template_input,
            planned.provider_body,
        ))
    }

    async fn plan_with_tokens(&self, request: PlanRequest) -> Result<Planned, PlanError> {
        let started = Instant::now();
        self.metrics.plan_started();
        if self.readiness() != Readiness::Ready {
            self.metrics.plan_not_ready(started.elapsed());
            return Err(PlanError::NotReady);
        }
        if request.scope_id.is_empty() || request.scope_id.len() > 256 {
            self.metrics.plan_finished(started.elapsed(), false);
            return Err(PlanError::InvalidScope);
        }
        let permit = match self.permits.clone().try_acquire_owned() {
            Ok(permit) => permit,
            Err(_) => {
                self.metrics.plan_at_capacity(started.elapsed());
                return Err(PlanError::AtCapacity);
            }
        };
        let planner = self.clone();
        let result =
            match tokio::task::spawn_blocking(move || planner.plan_sync(request, permit)).await {
                Ok(result) => result,
                Err(_) => Err(PlanError::Worker),
            };
        // Record completion only after the blocking task rejoins this request
        // future. If the HTTP deadline drops the future, the server records the
        // timeout and the detached worker cannot double-classify the request.
        match &result {
            Ok(_) => self.metrics.plan_finished(started.elapsed(), true),
            Err(PlanError::Render(render::RenderError::DynamicTime)) => {
                self.metrics.plan_cold_only(started.elapsed());
            }
            Err(_) => self.metrics.plan_finished(started.elapsed(), false),
        }
        result
    }

    fn plan_sync(
        &self,
        request: PlanRequest,
        _permit: OwnedSemaphorePermit,
    ) -> Result<Planned, PlanError> {
        let (contract, _) = self.load_contract(&request.prompt_contract_id)?;
        let lowered =
            endpoint::lower(request.endpoint, request.body).map_err(|_| PlanError::Endpoint)?;
        let provider_body = Value::Object(lowered.clone());
        let model_type = contract
            .model_config
            .get("model_type")
            .and_then(serde_json::Value::as_str);
        let normalized =
            normalize::normalize(lowered, model_type).map_err(|_| PlanError::Normalize)?;
        let prompt = render::render(&contract, &normalized).map_err(PlanError::Render)?;
        let encoding = contract
            .tokenizer
            .encode(prompt, false)
            .map_err(|_| PlanError::Tokenize)?;
        let token_ids = encoding.get_ids().to_vec();
        if token_ids.len() > self.max_tokens {
            return Err(PlanError::TooManyTokens);
        }
        let mut hashes = hash::chain_hashes(
            request.prompt_contract_id.as_bytes(),
            request.scope_id.as_bytes(),
            &token_ids,
            BLOCK_SIZE as usize,
        )
        .map_err(|_| PlanError::BlockHash)?;
        hashes.truncate(token_ids.len().saturating_sub(1) / BLOCK_SIZE as usize);
        let block_boundaries = hashes
            .iter()
            .enumerate()
            .map(|(index, hash)| BlockBoundary {
                token_count: ((index + 1) * BLOCK_SIZE as usize) as u32,
                chain_hash: hex::encode(hash),
            })
            .collect::<Vec<_>>();
        let last_complete_block_hash =
            hash::last_token_hash(&token_ids, &hashes, BLOCK_SIZE as usize).map(hex::encode);

        let prompt_token_count =
            u32::try_from(token_ids.len()).map_err(|_| PlanError::TooManyTokens)?;
        Ok(Planned {
            response: PlanResponse {
                prompt_contract_id: request.prompt_contract_id,
                prompt_token_count,
                block_boundaries,
                last_complete_block_hash,
            },
            token_ids,
            template_input: normalized.body,
            provider_body,
        })
    }

    fn load_contract(
        &self,
        contract_id: &str,
    ) -> Result<(Arc<LoadedArtifacts>, CacheAccess), PlanError> {
        let metrics = self.metrics.clone();
        let root = self.artifact_root.clone();
        let loaded = self.cache.get_or_load(contract_id, || {
            let started = Instant::now();
            let result = artifacts::load(&root, contract_id);
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
