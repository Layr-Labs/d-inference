//! Durable provider-partitioned replay-fence retry journal.

use std::{
    collections::{BTreeMap, VecDeque},
    path::PathBuf,
    sync::Mutex,
};

use darkbloom_coordinator_protocol::v2::{
    CoordinatorControlMessage, CoordinatorReplayFenceProof, ProviderId,
    ProviderProcessGenerationId, ReplayFenceProofId,
};
use serde::{Deserialize, Serialize};
use thiserror::Error;

use super::epoch_store::{DurableFileError, read_json_if_exists, write_json_atomic};

const REPLAY_STORE_VERSION: u32 = 1;

/// Finite dimensions of the replay journal.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ReplayStoreLimits {
    /// Stable provider partitions.
    pub maximum_providers: usize,
    /// Process generations retained under each provider.
    pub maximum_generations_per_provider: usize,
    /// Unacknowledged proofs retained under each generation.
    pub maximum_proofs_per_generation: usize,
}

impl ReplayStoreLimits {
    fn validate(self) -> Result<Self, ReplayStoreError> {
        if self.maximum_providers == 0
            || self.maximum_generations_per_provider == 0
            || self.maximum_proofs_per_generation == 0
        {
            return Err(ReplayStoreError::ZeroLimit);
        }
        Ok(self)
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct StoredReplay {
    proof: CoordinatorReplayFenceProof,
    retry_count: u32,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct GenerationPartition {
    generation: ProviderProcessGenerationId,
    proofs: VecDeque<StoredReplay>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct ProviderPartition {
    generations: VecDeque<GenerationPartition>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct ReplayFile {
    version: u32,
    providers: BTreeMap<ProviderId, ProviderPartition>,
}

/// One control-only retry returned to the provider writer.
#[derive(Clone, Debug, PartialEq)]
pub struct ReplayControl {
    /// A control-lane message; replay proofs are never data-lane frames.
    pub message: CoordinatorControlMessage,
    /// Durable send-attempt number, beginning at one.
    pub retry_count: u32,
}

/// Result of idempotently enqueueing a proof.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReplayEnqueue {
    /// New proof was fsynced.
    Inserted,
    /// The exact proof was already pending.
    Existing,
}

/// Provider-scoped durable proof journal.
#[derive(Debug)]
pub struct ReplayProofStore {
    path: PathBuf,
    limits: ReplayStoreLimits,
    state: Mutex<ReplayFile>,
}

impl ReplayProofStore {
    /// Opens and validates a finite replay journal.
    pub fn open(
        path: impl Into<PathBuf>,
        limits: ReplayStoreLimits,
    ) -> Result<Self, ReplayStoreError> {
        let limits = limits.validate()?;
        let path = path.into();
        let state = read_json_if_exists::<ReplayFile>(&path)?.unwrap_or(ReplayFile {
            version: REPLAY_STORE_VERSION,
            providers: BTreeMap::new(),
        });
        validate_loaded(&state, limits)?;
        Ok(Self {
            path,
            limits,
            state: Mutex::new(state),
        })
    }

    /// Adds a signed proof to its stable-provider/process-generation partition.
    pub fn enqueue(
        &self,
        proof: CoordinatorReplayFenceProof,
    ) -> Result<ReplayEnqueue, ReplayStoreError> {
        if !proof.digest_is_valid() || proof.coordinator_signature.is_empty() {
            return Err(ReplayStoreError::InvalidProof);
        }
        let mut state = self.lock_state();
        if let Some(existing) = find_proof(
            &state,
            proof.provider_id,
            proof.provider_process_generation,
            proof.proof_id,
        ) {
            return if existing.proof == proof {
                Ok(ReplayEnqueue::Existing)
            } else {
                Err(ReplayStoreError::ProofConflict {
                    provider_id: proof.provider_id,
                    proof_id: proof.proof_id,
                })
            };
        }
        if !state.providers.contains_key(&proof.provider_id)
            && state.providers.len() == self.limits.maximum_providers
        {
            return Err(ReplayStoreError::ProviderLimit {
                maximum: self.limits.maximum_providers,
            });
        }

        let mut candidate = state.clone();
        let provider = candidate.providers.entry(proof.provider_id).or_default();
        let generation_index = match provider
            .generations
            .iter()
            .position(|partition| partition.generation == proof.provider_process_generation)
        {
            Some(index) => index,
            None => {
                make_generation_room(
                    provider,
                    self.limits.maximum_generations_per_provider,
                    proof.provider_id,
                )?;
                provider.generations.push_back(GenerationPartition {
                    generation: proof.provider_process_generation,
                    proofs: VecDeque::new(),
                });
                provider.generations.len() - 1
            }
        };
        let generation = provider
            .generations
            .get_mut(generation_index)
            .expect("generation index came from the same partition");
        if generation.proofs.len() == self.limits.maximum_proofs_per_generation {
            return Err(ReplayStoreError::ProofLimit {
                provider_id: proof.provider_id,
                generation: proof.provider_process_generation,
                maximum: self.limits.maximum_proofs_per_generation,
            });
        }
        generation.proofs.push_back(StoredReplay {
            proof,
            retry_count: 0,
        });
        write_json_atomic(&self.path, &candidate)?;
        *state = candidate;
        Ok(ReplayEnqueue::Inserted)
    }

    /// Returns up to `maximum` proof retries and durably increments attempts.
    ///
    /// Every returned value is a coordinator control message, making it
    /// impossible for replay work to enter a payload/data lane.
    pub fn control_batch(
        &self,
        provider_id: ProviderId,
        generation: ProviderProcessGenerationId,
        maximum: usize,
    ) -> Result<Vec<ReplayControl>, ReplayStoreError> {
        if maximum == 0 {
            return Ok(Vec::new());
        }
        let mut state = self.lock_state();
        let Some(provider) = state.providers.get(&provider_id) else {
            return Ok(Vec::new());
        };
        let Some(partition) = provider
            .generations
            .iter()
            .find(|partition| partition.generation == generation)
        else {
            return Ok(Vec::new());
        };
        if partition.proofs.is_empty() {
            return Ok(Vec::new());
        }

        let mut candidate = state.clone();
        let proofs = candidate
            .providers
            .get_mut(&provider_id)
            .and_then(|provider| {
                provider
                    .generations
                    .iter_mut()
                    .find(|partition| partition.generation == generation)
            })
            .expect("candidate cloned the located partition");
        let mut controls = Vec::with_capacity(maximum.min(proofs.proofs.len()));
        for stored in proofs.proofs.iter_mut().take(maximum) {
            stored.retry_count =
                stored
                    .retry_count
                    .checked_add(1)
                    .ok_or(ReplayStoreError::RetryCountExhausted {
                        provider_id,
                        proof_id: stored.proof.proof_id,
                    })?;
            controls.push(ReplayControl {
                message: CoordinatorControlMessage::CoordinatorReplayFence(stored.proof.clone()),
                retry_count: stored.retry_count,
            });
        }
        write_json_atomic(&self.path, &candidate)?;
        *state = candidate;
        Ok(controls)
    }

    /// Removes only the matching provider/generation proof after acknowledgement.
    pub fn acknowledge(
        &self,
        provider_id: ProviderId,
        generation: ProviderProcessGenerationId,
        proof_id: ReplayFenceProofId,
    ) -> Result<bool, ReplayStoreError> {
        let mut state = self.lock_state();
        if find_proof(&state, provider_id, generation, proof_id).is_none() {
            return Ok(false);
        }
        let mut candidate = state.clone();
        let remove_provider = {
            let provider = candidate
                .providers
                .get_mut(&provider_id)
                .expect("candidate cloned the located provider partition");
            let partition = provider
                .generations
                .iter_mut()
                .find(|partition| partition.generation == generation)
                .expect("candidate cloned the located proof partition");
            partition
                .proofs
                .retain(|stored| stored.proof.proof_id != proof_id);
            provider
                .generations
                .retain(|partition| !partition.proofs.is_empty());
            provider.generations.is_empty()
        };
        if remove_provider {
            candidate.providers.remove(&provider_id);
        }
        write_json_atomic(&self.path, &candidate)?;
        *state = candidate;
        Ok(true)
    }

    /// Number of unacknowledged proofs across all bounded partitions.
    #[must_use]
    pub fn pending_len(&self) -> usize {
        self.lock_state()
            .providers
            .values()
            .flat_map(|provider| &provider.generations)
            .map(|generation| generation.proofs.len())
            .sum()
    }

    fn lock_state(&self) -> std::sync::MutexGuard<'_, ReplayFile> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

fn make_generation_room(
    provider: &mut ProviderPartition,
    maximum: usize,
    provider_id: ProviderId,
) -> Result<(), ReplayStoreError> {
    while provider.generations.len() >= maximum {
        let Some(empty) = provider
            .generations
            .iter()
            .position(|partition| partition.proofs.is_empty())
        else {
            return Err(ReplayStoreError::GenerationLimit {
                provider_id,
                maximum,
            });
        };
        provider.generations.remove(empty);
    }
    Ok(())
}

fn find_proof(
    state: &ReplayFile,
    provider_id: ProviderId,
    generation: ProviderProcessGenerationId,
    proof_id: ReplayFenceProofId,
) -> Option<&StoredReplay> {
    state
        .providers
        .get(&provider_id)?
        .generations
        .iter()
        .find(|partition| partition.generation == generation)?
        .proofs
        .iter()
        .find(|stored| stored.proof.proof_id == proof_id)
}

fn validate_loaded(state: &ReplayFile, limits: ReplayStoreLimits) -> Result<(), ReplayStoreError> {
    if state.version != REPLAY_STORE_VERSION {
        return Err(ReplayStoreError::UnsupportedVersion(state.version));
    }
    if state.providers.len() > limits.maximum_providers {
        return Err(ReplayStoreError::ProviderLimit {
            maximum: limits.maximum_providers,
        });
    }
    for (provider_id, provider) in &state.providers {
        if provider.generations.len() > limits.maximum_generations_per_provider {
            return Err(ReplayStoreError::GenerationLimit {
                provider_id: *provider_id,
                maximum: limits.maximum_generations_per_provider,
            });
        }
        for generation in &provider.generations {
            if generation.proofs.len() > limits.maximum_proofs_per_generation {
                return Err(ReplayStoreError::ProofLimit {
                    provider_id: *provider_id,
                    generation: generation.generation,
                    maximum: limits.maximum_proofs_per_generation,
                });
            }
            if generation.proofs.iter().any(|stored| {
                stored.proof.provider_id != *provider_id
                    || stored.proof.provider_process_generation != generation.generation
                    || !stored.proof.digest_is_valid()
                    || stored.proof.coordinator_signature.is_empty()
            }) {
                return Err(ReplayStoreError::InvalidProof);
            }
        }
    }
    Ok(())
}

/// Replay journal failure. Every identity-bearing error is provider-local.
#[derive(Debug, Error)]
pub enum ReplayStoreError {
    /// All finite dimensions must be positive.
    #[error("replay store limits must be greater than zero")]
    ZeroLimit,
    /// Stable provider partition bound was reached.
    #[error("replay store provider limit of {maximum} reached")]
    ProviderLimit {
        /// Configured bound.
        maximum: usize,
    },
    /// No empty historical generation can be evicted safely.
    #[error("provider {provider_id} replay generation limit of {maximum} reached")]
    GenerationLimit {
        /// Affected stable provider.
        provider_id: ProviderId,
        /// Per-provider bound.
        maximum: usize,
    },
    /// One generation's unacknowledged journal is full.
    #[error(
        "provider {provider_id} generation {generation} replay proof limit of {maximum} reached"
    )]
    ProofLimit {
        /// Affected stable provider.
        provider_id: ProviderId,
        /// Affected process generation.
        generation: ProviderProcessGenerationId,
        /// Per-generation bound.
        maximum: usize,
    },
    /// Reusing a proof ID with different bytes affects only that provider.
    #[error("provider {provider_id} replay proof {proof_id} conflicts with pending proof")]
    ProofConflict {
        /// Affected stable provider.
        provider_id: ProviderId,
        /// Reused proof identifier.
        proof_id: ReplayFenceProofId,
    },
    /// Proof digest/signature shape is not safe to journal.
    #[error("invalid coordinator replay-fence proof")]
    InvalidProof,
    /// Retry count cannot wrap.
    #[error("provider {provider_id} replay proof {proof_id} retry count exhausted")]
    RetryCountExhausted {
        /// Affected stable provider.
        provider_id: ProviderId,
        /// Affected proof.
        proof_id: ReplayFenceProofId,
    },
    /// On-disk schema is incompatible.
    #[error("unsupported replay store version {0}")]
    UnsupportedVersion(u32),
    /// Durable journal operation failed.
    #[error(transparent)]
    Durable(#[from] DurableFileError),
}

#[cfg(test)]
mod tests {
    use std::fs;

    use darkbloom_coordinator_protocol::v2::SessionEpoch;
    use uuid::Uuid;

    use super::*;
    use crate::crypto::ReplayProofSigner;

    fn path(label: &str) -> PathBuf {
        std::env::temp_dir().join(format!("{label}-{}.json", Uuid::new_v4()))
    }

    fn limits() -> ReplayStoreLimits {
        ReplayStoreLimits {
            maximum_providers: 4,
            maximum_generations_per_provider: 2,
            maximum_proofs_per_generation: 2,
        }
    }

    #[test]
    fn retry_is_control_only_ack_removes_and_restart_is_durable() {
        let signer_path = path("darkbloom-replay-signer");
        let store_path = path("darkbloom-replay-store");
        let signer = ReplayProofSigner::open(&signer_path).expect("signer");
        let provider = ProviderId::new([1; 16]);
        let generation = ProviderProcessGenerationId::new([2; 16]);
        let proof = signer.sign(provider, generation, SessionEpoch(8), 3);
        let proof_id = proof.proof_id;
        let store = ReplayProofStore::open(&store_path, limits()).expect("store");
        assert_eq!(
            store.enqueue(proof.clone()).expect("enqueue"),
            ReplayEnqueue::Inserted
        );
        assert_eq!(
            store.enqueue(proof).expect("idempotent"),
            ReplayEnqueue::Existing
        );
        let batch = store.control_batch(provider, generation, 1).expect("batch");
        assert_eq!(batch.len(), 1);
        assert_eq!(batch[0].retry_count, 1);
        assert!(matches!(
            batch[0].message,
            CoordinatorControlMessage::CoordinatorReplayFence(_)
        ));
        drop(store);

        let restarted = ReplayProofStore::open(&store_path, limits()).expect("restart");
        assert_eq!(restarted.pending_len(), 1);
        assert!(
            restarted
                .acknowledge(provider, generation, proof_id)
                .expect("ack")
        );
        assert_eq!(restarted.pending_len(), 0);
        let _ = fs::remove_file(signer_path);
        let _ = fs::remove_file(store_path);
    }

    #[test]
    fn acknowledged_provider_and_generation_churn_cannot_poison_other_providers() {
        let signer_path = path("darkbloom-replay-churn-signer");
        let store_path = path("darkbloom-replay-churn-store");
        let signer = ReplayProofSigner::open(&signer_path).expect("signer");
        let store = ReplayProofStore::open(
            &store_path,
            ReplayStoreLimits {
                maximum_providers: 1,
                maximum_generations_per_provider: 2,
                maximum_proofs_per_generation: 2,
            },
        )
        .expect("store");
        let provider = ProviderId::new([1; 16]);
        for value in 1..=100_u128 {
            let generation = ProviderProcessGenerationId::new(value.to_be_bytes());
            let proof = signer.sign(
                provider,
                generation,
                SessionEpoch(value as u64),
                value as u64,
            );
            let id = proof.proof_id;
            store.enqueue(proof).expect("bounded enqueue");
            store
                .acknowledge(provider, generation, id)
                .expect("acknowledge");
        }
        let other = ProviderId::new([9; 16]);
        let generation = ProviderProcessGenerationId::new([8; 16]);
        store
            .enqueue(signer.sign(other, generation, SessionEpoch(1), 1))
            .expect("other provider remains healthy");
        assert_eq!(store.pending_len(), 1);
        let _ = fs::remove_file(signer_path);
        let _ = fs::remove_file(store_path);
    }

    #[test]
    fn one_providers_full_generation_partition_does_not_poison_another() {
        let signer_path = path("darkbloom-replay-local-limit-signer");
        let store_path = path("darkbloom-replay-local-limit-store");
        let signer = ReplayProofSigner::open(&signer_path).expect("signer");
        let store = ReplayProofStore::open(
            &store_path,
            ReplayStoreLimits {
                maximum_providers: 2,
                maximum_generations_per_provider: 1,
                maximum_proofs_per_generation: 1,
            },
        )
        .expect("store");
        let full_provider = ProviderId::new([1; 16]);
        store
            .enqueue(signer.sign(
                full_provider,
                ProviderProcessGenerationId::new([2; 16]),
                SessionEpoch(1),
                1,
            ))
            .expect("first generation");
        assert!(matches!(
            store.enqueue(signer.sign(
                full_provider,
                ProviderProcessGenerationId::new([3; 16]),
                SessionEpoch(2),
                2,
            )),
            Err(ReplayStoreError::GenerationLimit {
                provider_id,
                maximum: 1
            }) if provider_id == full_provider
        ));

        let healthy_provider = ProviderId::new([9; 16]);
        store
            .enqueue(signer.sign(
                healthy_provider,
                ProviderProcessGenerationId::new([8; 16]),
                SessionEpoch(1),
                1,
            ))
            .expect("unrelated provider remains healthy");
        assert_eq!(store.pending_len(), 2);
        let _ = fs::remove_file(signer_path);
        let _ = fs::remove_file(store_path);
    }
}
