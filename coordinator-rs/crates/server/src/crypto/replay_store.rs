//! Durable provider-partitioned replay-fence retry journal.

use std::{
    collections::{BTreeMap, VecDeque},
    fs, io,
    path::{Path, PathBuf},
    sync::Mutex,
};

use darkbloom_coordinator_protocol::v2::{
    CoordinatorControlMessage, CoordinatorReplayFenceProof, ProviderId,
    ProviderProcessGenerationId, ReplayFenceProofId, SessionEpoch,
};
use serde::{Deserialize, Serialize};
use thiserror::Error;

use super::DurableIoError;
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
    #[serde(default)]
    obligations: VecDeque<ReplayObligation>,
    generations: VecDeque<GenerationPartition>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct ReplayFile {
    version: u32,
    providers: BTreeMap<ProviderId, ProviderPartition>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct ReplayProviderFile {
    version: u32,
    provider_id: ProviderId,
    partition: ProviderPartition,
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

/// Durable fail-closed marker created before a v2 session is acknowledged.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
pub struct ReplayObligation {
    /// Stable provider whose session must eventually be fenced.
    pub provider_id: ProviderId,
    /// Process generation bound into the future signed proof.
    pub provider_process_generation: ProviderProcessGenerationId,
    /// Exact acknowledged WebSocket epoch.
    pub session_epoch: SessionEpoch,
}

/// Provider-scoped durable proof journal.
#[derive(Debug)]
pub struct ReplayProofStore {
    path: PathBuf,
    partition_directory: PathBuf,
    legacy_monolith: bool,
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
        let legacy = read_json_if_exists::<ReplayFile>(&path)?;
        let partition_directory = path.with_extension("partitions");
        let legacy_monolith = legacy.is_some();
        let mut state = legacy.unwrap_or(ReplayFile {
            version: REPLAY_STORE_VERSION,
            providers: BTreeMap::new(),
        });
        if !legacy_monolith {
            load_provider_partitions(&partition_directory, limits, &mut state)?;
        }
        validate_loaded(&state, limits)?;
        Ok(Self {
            path,
            partition_directory,
            legacy_monolith,
            limits,
            state: Mutex::new(state),
        })
    }

    /// Fsyncs a fail-closed obligation before a v2 RegisterAck can be sent.
    pub fn reserve_obligation(
        &self,
        obligation: ReplayObligation,
    ) -> Result<ReplayEnqueue, ReplayStoreError> {
        if obligation.session_epoch.0 == 0 {
            return Err(ReplayStoreError::InvalidObligation);
        }
        let mut state = self.lock_state();
        if has_epoch(
            &state,
            obligation.provider_id,
            obligation.provider_process_generation,
            obligation.session_epoch,
        ) {
            return Ok(ReplayEnqueue::Existing);
        }
        ensure_provider_room(&state, obligation.provider_id, self.limits)?;

        let mut candidate = state.clone();
        let provider = candidate
            .providers
            .entry(obligation.provider_id)
            .or_default();
        let maximum_obligations = self
            .limits
            .maximum_generations_per_provider
            .saturating_mul(self.limits.maximum_proofs_per_generation)
            .saturating_add(1);
        if provider.obligations.len() == maximum_obligations {
            return Err(ReplayStoreError::ObligationLimit {
                provider_id: obligation.provider_id,
                maximum: maximum_obligations,
            });
        }
        provider.obligations.push_back(obligation);
        self.persist_provider(obligation.provider_id, &candidate)?;
        *state = candidate;
        Ok(ReplayEnqueue::Inserted)
    }

    /// Atomically replaces one exact durable obligation with its signed proof.
    pub fn fulfill_obligation(
        &self,
        proof: CoordinatorReplayFenceProof,
    ) -> Result<ReplayEnqueue, ReplayStoreError> {
        validate_proof(&proof)?;
        let mut state = self.lock_state();
        if state
            .providers
            .get(&proof.provider_id)
            .into_iter()
            .flat_map(|provider| &provider.generations)
            .filter(|partition| partition.generation == proof.provider_process_generation)
            .flat_map(|partition| &partition.proofs)
            .any(|stored| stored.proof.through_session_epoch == proof.through_session_epoch)
        {
            return Ok(ReplayEnqueue::Existing);
        }
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

        let mut candidate = state.clone();
        let provider = candidate.providers.get_mut(&proof.provider_id).ok_or(
            ReplayStoreError::MissingObligation {
                provider_id: proof.provider_id,
                generation: proof.provider_process_generation,
                session_epoch: proof.through_session_epoch,
            },
        )?;
        let Some(index) = provider.obligations.iter().position(|obligation| {
            obligation.provider_process_generation == proof.provider_process_generation
                && obligation.session_epoch == proof.through_session_epoch
        }) else {
            return Err(ReplayStoreError::MissingObligation {
                provider_id: proof.provider_id,
                generation: proof.provider_process_generation,
                session_epoch: proof.through_session_epoch,
            });
        };
        generation_for_insert(
            &mut candidate,
            proof.provider_id,
            proof.provider_process_generation,
            self.limits,
        )?;
        let provider = candidate
            .providers
            .get_mut(&proof.provider_id)
            .expect("provider containing obligation remains present");
        provider.obligations.remove(index);
        let generation = provider
            .generations
            .iter_mut()
            .find(|partition| partition.generation == proof.provider_process_generation)
            .expect("generation was inserted above");
        if generation.proofs.len() == self.limits.maximum_proofs_per_generation {
            return Err(ReplayStoreError::ProofLimit {
                provider_id: proof.provider_id,
                generation: proof.provider_process_generation,
                maximum: self.limits.maximum_proofs_per_generation,
            });
        }
        generation.proofs.push_back(StoredReplay {
            proof: proof.clone(),
            retry_count: 0,
        });
        self.persist_provider(proof.provider_id, &candidate)?;
        *state = candidate;
        Ok(ReplayEnqueue::Inserted)
    }

    /// Returns owned unfinished markers for one stable provider.
    #[must_use]
    pub fn obligations_for_provider(&self, provider_id: ProviderId) -> Vec<ReplayObligation> {
        self.lock_state()
            .providers
            .get(&provider_id)
            .into_iter()
            .flat_map(|provider| &provider.obligations)
            .copied()
            .collect()
    }

    /// Adds a signed proof to its stable-provider/process-generation partition.
    pub fn enqueue(
        &self,
        proof: CoordinatorReplayFenceProof,
    ) -> Result<ReplayEnqueue, ReplayStoreError> {
        validate_proof(&proof)?;
        let proof_provider_id = proof.provider_id;
        let mut state = self.lock_state();
        if state
            .providers
            .get(&proof.provider_id)
            .into_iter()
            .flat_map(|provider| &provider.generations)
            .filter(|partition| partition.generation == proof.provider_process_generation)
            .flat_map(|partition| &partition.proofs)
            .any(|stored| stored.proof.through_session_epoch == proof.through_session_epoch)
        {
            // One durable tombstone per ended session is sufficient. Session
            // replacement and old-owner teardown may both observe the same
            // end, but must not consume two bounded proof slots.
            return Ok(ReplayEnqueue::Existing);
        }
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
        ensure_provider_room(&state, proof.provider_id, self.limits)?;

        let mut candidate = state.clone();
        let generation = generation_for_insert(
            &mut candidate,
            proof.provider_id,
            proof.provider_process_generation,
            self.limits,
        )?;
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
        self.persist_provider(proof_provider_id, &candidate)?;
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
        self.persist_provider(provider_id, &candidate)?;
        *state = candidate;
        Ok(controls)
    }

    /// Returns retries across one stable provider's historical generations.
    ///
    /// A current WebSocket may carry proofs for older process generations, so
    /// retry selection is provider-scoped while acknowledgement remains bound
    /// to the proof's exact generation partition.
    pub fn control_batch_for_provider(
        &self,
        provider_id: ProviderId,
        maximum: usize,
    ) -> Result<Vec<ReplayControl>, ReplayStoreError> {
        if maximum == 0 {
            return Ok(Vec::new());
        }
        let mut state = self.lock_state();
        let Some(provider) = state.providers.get(&provider_id) else {
            return Ok(Vec::new());
        };
        if provider
            .generations
            .iter()
            .all(|partition| partition.proofs.is_empty())
        {
            return Ok(Vec::new());
        }

        let mut candidate = state.clone();
        let partitions = &mut candidate
            .providers
            .get_mut(&provider_id)
            .expect("candidate cloned the located provider partition")
            .generations;
        let mut controls = Vec::with_capacity(maximum);
        for partition in partitions {
            for stored in &mut partition.proofs {
                if controls.len() == maximum {
                    break;
                }
                stored.retry_count = stored.retry_count.checked_add(1).ok_or(
                    ReplayStoreError::RetryCountExhausted {
                        provider_id,
                        proof_id: stored.proof.proof_id,
                    },
                )?;
                controls.push(ReplayControl {
                    message: CoordinatorControlMessage::CoordinatorReplayFence(
                        stored.proof.clone(),
                    ),
                    retry_count: stored.retry_count,
                });
            }
            if controls.len() == maximum {
                break;
            }
        }
        self.persist_provider(provider_id, &candidate)?;
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
            provider.generations.is_empty() && provider.obligations.is_empty()
        };
        if remove_provider {
            candidate.providers.remove(&provider_id);
        }
        self.persist_provider(provider_id, &candidate)?;
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

    /// Number of unacknowledged proofs for one provider process generation.
    #[must_use]
    pub fn pending_for(
        &self,
        provider_id: ProviderId,
        generation: ProviderProcessGenerationId,
    ) -> usize {
        self.lock_state()
            .providers
            .get(&provider_id)
            .and_then(|provider| {
                provider
                    .generations
                    .iter()
                    .find(|partition| partition.generation == generation)
            })
            .map_or(0, |partition| partition.proofs.len())
    }

    /// Number of unacknowledged proofs across one provider's generations.
    #[must_use]
    pub fn pending_for_provider(&self, provider_id: ProviderId) -> usize {
        self.lock_state()
            .providers
            .get(&provider_id)
            .map_or(0, |provider| {
                provider
                    .generations
                    .iter()
                    .map(|partition| partition.proofs.len())
                    .sum()
            })
    }

    fn lock_state(&self) -> std::sync::MutexGuard<'_, ReplayFile> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn persist_provider(
        &self,
        provider_id: ProviderId,
        candidate: &ReplayFile,
    ) -> Result<(), ReplayStoreError> {
        if self.legacy_monolith {
            write_json_atomic(&self.path, candidate)?;
        } else {
            let path = provider_partition_path(&self.partition_directory, provider_id);
            if let Some(partition) = candidate.providers.get(&provider_id) {
                write_json_atomic(
                    &path,
                    &ReplayProviderFile {
                        version: REPLAY_STORE_VERSION,
                        provider_id,
                        partition: partition.clone(),
                    },
                )?;
            } else {
                remove_json_atomic(&path)?;
            }
        }
        crate::fault_checkpoint_sync!(
            ReplayProofFsync,
            "ReplayProofStore::persist_provider",
            |error| ReplayStoreError::InjectedFault(error.point().as_str())
        );
        Ok(())
    }
}

fn load_provider_partitions(
    directory: &Path,
    limits: ReplayStoreLimits,
    state: &mut ReplayFile,
) -> Result<(), ReplayStoreError> {
    let entries = match fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(source) if source.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(source) => return Err(durable_io_error(directory, source).into()),
    };
    for entry in entries {
        let entry = entry.map_err(|source| durable_io_error(directory, source))?;
        if entry.path().extension().and_then(|value| value.to_str()) != Some("json") {
            continue;
        }
        if state.providers.len() == limits.maximum_providers {
            return Err(ReplayStoreError::ProviderLimit {
                maximum: limits.maximum_providers,
            });
        }
        let file = read_json_if_exists::<ReplayProviderFile>(&entry.path())?
            .ok_or(ReplayStoreError::InvalidProof)?;
        if file.version != REPLAY_STORE_VERSION
            || state
                .providers
                .insert(file.provider_id, file.partition)
                .is_some()
        {
            return Err(ReplayStoreError::InvalidProof);
        }
    }
    Ok(())
}

fn provider_partition_path(directory: &Path, provider_id: ProviderId) -> PathBuf {
    directory.join(format!("{provider_id}.json"))
}

fn remove_json_atomic(path: &Path) -> Result<(), DurableFileError> {
    match fs::remove_file(path) {
        Ok(()) => {}
        Err(source) if source.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(source) => return Err(durable_io_error(path, source)),
    }
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    std::fs::File::open(parent)
        .and_then(|directory| directory.sync_all())
        .map_err(|source| durable_io_error(parent, source))
}

fn durable_io_error(path: &Path, source: io::Error) -> DurableFileError {
    DurableFileError::Io {
        path: path.to_path_buf(),
        source,
    }
}

fn validate_proof(proof: &CoordinatorReplayFenceProof) -> Result<(), ReplayStoreError> {
    if proof.digest_is_valid() && !proof.coordinator_signature.is_empty() {
        Ok(())
    } else {
        Err(ReplayStoreError::InvalidProof)
    }
}

fn ensure_provider_room(
    state: &ReplayFile,
    provider_id: ProviderId,
    limits: ReplayStoreLimits,
) -> Result<(), ReplayStoreError> {
    if !state.providers.contains_key(&provider_id)
        && state.providers.len() == limits.maximum_providers
    {
        Err(ReplayStoreError::ProviderLimit {
            maximum: limits.maximum_providers,
        })
    } else {
        Ok(())
    }
}

fn generation_for_insert(
    state: &mut ReplayFile,
    provider_id: ProviderId,
    generation: ProviderProcessGenerationId,
    limits: ReplayStoreLimits,
) -> Result<&mut GenerationPartition, ReplayStoreError> {
    let provider = state.providers.entry(provider_id).or_default();
    let index = match provider
        .generations
        .iter()
        .position(|partition| partition.generation == generation)
    {
        Some(index) => index,
        None => {
            make_generation_room(
                provider,
                limits.maximum_generations_per_provider,
                provider_id,
            )?;
            provider.generations.push_back(GenerationPartition {
                generation,
                proofs: VecDeque::new(),
            });
            provider.generations.len() - 1
        }
    };
    Ok(provider
        .generations
        .get_mut(index)
        .expect("generation index came from the same partition"))
}

fn has_epoch(
    state: &ReplayFile,
    provider_id: ProviderId,
    generation: ProviderProcessGenerationId,
    epoch: SessionEpoch,
) -> bool {
    state
        .providers
        .get(&provider_id)
        .into_iter()
        .any(|provider| {
            provider.obligations.iter().any(|obligation| {
                obligation.provider_process_generation == generation
                    && obligation.session_epoch == epoch
            }) || provider
                .generations
                .iter()
                .filter(|partition| partition.generation == generation)
                .flat_map(|partition| &partition.proofs)
                .any(|stored| stored.proof.through_session_epoch == epoch)
        })
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
        let maximum_obligations = limits
            .maximum_generations_per_provider
            .saturating_mul(limits.maximum_proofs_per_generation)
            .saturating_add(1);
        if provider.obligations.len() > maximum_obligations {
            return Err(ReplayStoreError::ObligationLimit {
                provider_id: *provider_id,
                maximum: maximum_obligations,
            });
        }
        for (index, obligation) in provider.obligations.iter().enumerate() {
            if obligation.provider_id != *provider_id
                || obligation.session_epoch.0 == 0
                || provider.generations.iter().any(|generation| {
                    generation.generation == obligation.provider_process_generation
                        && generation.proofs.iter().any(|stored| {
                            stored.proof.through_session_epoch == obligation.session_epoch
                        })
                })
                || provider.obligations.iter().skip(index + 1).any(|other| {
                    other.provider_process_generation == obligation.provider_process_generation
                        && other.session_epoch == obligation.session_epoch
                })
            {
                return Err(ReplayStoreError::InvalidObligation);
            }
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
    /// Fail-closed session markers exhausted their provider-local bound.
    #[error("provider {provider_id} replay obligation limit of {maximum} reached")]
    ObligationLimit {
        /// Affected stable provider.
        provider_id: ProviderId,
        /// Per-provider marker bound.
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
    /// A fail-closed teardown marker was malformed.
    #[error("invalid provider replay-fence obligation")]
    InvalidObligation,
    /// Teardown attempted to create a proof without its pre-ACK marker.
    #[error(
        "provider {provider_id} generation {generation} epoch {session_epoch:?} has no replay obligation"
    )]
    MissingObligation {
        /// Stable provider whose obligation was missing.
        provider_id: ProviderId,
        /// Process generation whose obligation was missing.
        generation: ProviderProcessGenerationId,
        /// Exact ended WebSocket epoch.
        session_epoch: SessionEpoch,
    },
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
    /// Deliberate test-only persistence failure.
    #[cfg(feature = "fault-injection")]
    #[error("injected replay-store fault at {0}")]
    InjectedFault(&'static str),
    /// Durable journal operation failed.
    #[error(transparent)]
    Durable(#[from] DurableFileError),
    /// Bounded blocking-I/O offload failed before the store result was known.
    #[error(transparent)]
    IoPool(DurableIoError),
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
    fn current_connection_retries_and_acks_historical_generation_partition() {
        let signer_path = path("darkbloom-replay-historical-signer");
        let store_path = path("darkbloom-replay-historical-store");
        let signer = ReplayProofSigner::open(&signer_path).expect("signer");
        let store = ReplayProofStore::open(&store_path, limits()).expect("store");
        let provider = ProviderId::new([1; 16]);
        let historical = ProviderProcessGenerationId::new([2; 16]);
        let current = ProviderProcessGenerationId::new([3; 16]);
        let old = signer.sign(provider, historical, SessionEpoch(8), 3);
        let old_id = old.proof_id;
        let new = signer.sign(provider, current, SessionEpoch(9), 4);
        let new_id = new.proof_id;
        store.enqueue(old).expect("historical proof");
        store.enqueue(new).expect("current proof");

        let batch = store
            .control_batch_for_provider(provider, 8)
            .expect("provider batch");
        assert_eq!(batch.len(), 2);
        assert!(batch.iter().all(|control| control.retry_count == 1));
        assert_eq!(store.pending_for_provider(provider), 2);
        assert!(
            store
                .acknowledge(provider, historical, old_id)
                .expect("historical ACK")
        );
        assert_eq!(store.pending_for_provider(provider), 1);
        assert!(
            store
                .acknowledge(provider, current, new_id)
                .expect("current ACK")
        );
        assert_eq!(store.pending_for_provider(provider), 0);

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

    #[cfg(unix)]
    #[test]
    fn failed_fulfillment_keeps_fail_closed_obligation_across_restart() {
        use std::os::unix::fs::PermissionsExt;

        let signer_path = path("darkbloom-replay-obligation-signer");
        let store_path = path("darkbloom-replay-obligation-store");
        let signer = ReplayProofSigner::open(&signer_path).expect("signer");
        let provider = ProviderId::new([7; 16]);
        let generation = ProviderProcessGenerationId::new([8; 16]);
        let obligation = ReplayObligation {
            provider_id: provider,
            provider_process_generation: generation,
            session_epoch: SessionEpoch(9),
        };
        let store = ReplayProofStore::open(&store_path, limits()).expect("store");
        store
            .reserve_obligation(obligation)
            .expect("durable obligation");

        let partition_directory = store.partition_directory.clone();
        let original_permissions = fs::metadata(&partition_directory)
            .expect("partition metadata")
            .permissions();
        fs::set_permissions(&partition_directory, fs::Permissions::from_mode(0o500))
            .expect("make replay directory read-only");
        let proof = signer.sign(provider, generation, SessionEpoch(9), 1);
        assert!(matches!(
            store.fulfill_obligation(proof.clone()),
            Err(ReplayStoreError::Durable(_))
        ));
        fs::set_permissions(&partition_directory, original_permissions)
            .expect("restore replay directory");
        drop(store);

        let restarted = ReplayProofStore::open(&store_path, limits()).expect("restart store");
        assert_eq!(
            restarted.obligations_for_provider(provider),
            vec![obligation]
        );
        restarted
            .fulfill_obligation(proof)
            .expect("repair obligation after restart");
        assert!(restarted.obligations_for_provider(provider).is_empty());
        assert_eq!(restarted.pending_for_provider(provider), 1);

        let _ = fs::remove_file(signer_path);
        let _ = fs::remove_file(store_path);
        let _ = fs::remove_dir_all(partition_directory);
    }
}
