use crate::api::{BlockBoundary, PlanRequest, PlanResponse};
use crate::artifacts::{self, LoadedArtifacts};
use crate::contract::BLOCK_SIZE;
use crate::endpoint;
use crate::hash;
use crate::normalize;
use crate::render;
use serde_json::Value;
use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use thiserror::Error;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

#[derive(Clone)]
pub struct Planner {
    artifact_root: Arc<PathBuf>,
    cache: Arc<Mutex<ArtifactCache>>,
    permits: Arc<Semaphore>,
    max_tokens: usize,
}

struct ArtifactCache {
    entries: HashMap<String, Arc<LoadedArtifacts>>,
    order: VecDeque<String>,
    capacity: usize,
}

struct Planned {
    response: PlanResponse,
    token_ids: Vec<u32>,
    template_input: Value,
    provider_body: Value,
}

#[derive(Debug, Error)]
pub enum PlanError {
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

impl Planner {
    pub fn new(
        artifact_root: PathBuf,
        max_concurrency: usize,
        max_loaded_contracts: usize,
        max_tokens: usize,
    ) -> Self {
        Self {
            artifact_root: Arc::new(artifact_root),
            cache: Arc::new(Mutex::new(ArtifactCache {
                entries: HashMap::new(),
                order: VecDeque::new(),
                capacity: max_loaded_contracts.max(1),
            })),
            permits: Arc::new(Semaphore::new(max_concurrency.max(1))),
            max_tokens,
        }
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
        if request.scope_id.is_empty() || request.scope_id.len() > 256 {
            return Err(PlanError::InvalidScope);
        }
        let permit = self
            .permits
            .clone()
            .try_acquire_owned()
            .map_err(|_| PlanError::AtCapacity)?;
        let planner = self.clone();
        tokio::task::spawn_blocking(move || planner.plan_sync(request, permit))
            .await
            .map_err(|_| PlanError::Worker)?
    }

    fn plan_sync(
        &self,
        request: PlanRequest,
        _permit: OwnedSemaphorePermit,
    ) -> Result<Planned, PlanError> {
        let contract = self.load_contract(&request.prompt_contract_id)?;
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

    fn load_contract(&self, contract_id: &str) -> Result<Arc<LoadedArtifacts>, PlanError> {
        {
            let mut cache = self.cache.lock().map_err(|_| PlanError::Contract)?;
            if let Some(contract) = cache.entries.get(contract_id).cloned() {
                touch(&mut cache.order, contract_id);
                return Ok(contract);
            }
        }
        let loaded = Arc::new(
            artifacts::load(&self.artifact_root, contract_id).map_err(|_| PlanError::Contract)?,
        );
        let mut cache = self.cache.lock().map_err(|_| PlanError::Contract)?;
        if let Some(existing) = cache.entries.get(contract_id).cloned() {
            touch(&mut cache.order, contract_id);
            return Ok(existing);
        }
        while cache.entries.len() >= cache.capacity {
            if let Some(oldest) = cache.order.pop_front() {
                cache.entries.remove(&oldest);
            }
        }
        cache.entries.insert(contract_id.into(), loaded.clone());
        cache.order.push_back(contract_id.into());
        Ok(loaded)
    }
}

fn touch(order: &mut VecDeque<String>, contract_id: &str) {
    if let Some(index) = order.iter().position(|value| value == contract_id) {
        order.remove(index);
    }
    order.push_back(contract_id.into());
}
