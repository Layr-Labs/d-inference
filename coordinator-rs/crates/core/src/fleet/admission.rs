//! Exact token, KV-cache, concurrency, health, and trait admission checks.

use thiserror::Error;

use crate::{
    ids::PermitId,
    tokens::{KvBytes, ResourceArithmeticError, TokenCount},
    traits::{CompatibilityError, RequestTraits},
};

use super::{
    health::HealthMode,
    state::{CapacityError, CapacitySnapshot, ProviderSnapshot},
};

/// Resource demand for one request.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AdmissionDemand {
    prompt_tokens: TokenCount,
    maximum_completion_tokens: TokenCount,
    total_tokens: TokenCount,
    kv_bytes: KvBytes,
}

impl AdmissionDemand {
    /// Creates a demand, rejecting prompt-plus-completion overflow.
    pub fn new(
        prompt_tokens: TokenCount,
        maximum_completion_tokens: TokenCount,
        kv_bytes: KvBytes,
    ) -> Result<Self, AdmissionError> {
        let total_tokens = prompt_tokens.checked_add(maximum_completion_tokens)?;
        Ok(Self {
            prompt_tokens,
            maximum_completion_tokens,
            total_tokens,
            kv_bytes,
        })
    }

    /// Returns the prompt token estimate.
    #[must_use]
    pub const fn prompt_tokens(self) -> TokenCount {
        self.prompt_tokens
    }

    /// Returns the maximum completion token count.
    #[must_use]
    pub const fn maximum_completion_tokens(self) -> TokenCount {
        self.maximum_completion_tokens
    }

    /// Returns prompt plus maximum completion tokens.
    #[must_use]
    pub const fn total_tokens(self) -> TokenCount {
        self.total_tokens
    }

    /// Returns required KV-cache bytes.
    #[must_use]
    pub const fn kv_bytes(self) -> KvBytes {
        self.kv_bytes
    }
}

/// Whether admission is for ordinary traffic or the claimed half-open probe.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AdmissionKind {
    /// Ordinary closed-circuit traffic.
    Regular,
    /// The sole claimed half-open probe.
    Probe(PermitId),
}

/// Successful admission and projected immutable capacity.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Admission {
    /// Resource quantities reserved by this decision.
    pub demand: AdmissionDemand,
    /// Capacity counters after committing this decision.
    pub projected_capacity: CapacitySnapshot,
}

/// Checks all admission constraints and returns projected counters.
pub fn admit(
    provider: &ProviderSnapshot,
    request_traits: &RequestTraits,
    demand: AdmissionDemand,
    kind: AdmissionKind,
) -> Result<Admission, AdmissionError> {
    if request_traits.context_tokens() != demand.total_tokens {
        return Err(AdmissionError::ContextTokenMismatch {
            traits: request_traits.context_tokens(),
            demand: demand.total_tokens,
        });
    }
    check_health(provider, kind)?;
    provider.traits().check(request_traits)?;

    let capacity = provider.capacity();
    let projected_tokens = capacity.tokens_in_use().checked_add(demand.total_tokens)?;
    if projected_tokens > capacity.token_capacity() {
        return Err(AdmissionError::TokenBudgetExceeded {
            capacity: capacity.token_capacity(),
            in_use: capacity.tokens_in_use(),
            requested: demand.total_tokens,
        });
    }

    let projected_kv = capacity.kv_in_use().checked_add(demand.kv_bytes)?;
    if projected_kv > capacity.kv_capacity() {
        return Err(AdmissionError::KvBudgetExceeded {
            capacity: capacity.kv_capacity(),
            in_use: capacity.kv_in_use(),
            requested: demand.kv_bytes,
        });
    }

    let projected_concurrency = capacity
        .concurrency_in_use()
        .checked_add(1)
        .ok_or(AdmissionError::ConcurrencyOverflow)?;
    if projected_concurrency > capacity.concurrency_limit() {
        return Err(AdmissionError::ConcurrencyExceeded {
            limit: capacity.concurrency_limit(),
            in_use: capacity.concurrency_in_use(),
        });
    }

    let projected_capacity = CapacitySnapshot::new(
        capacity.token_capacity(),
        projected_tokens,
        capacity.kv_capacity(),
        projected_kv,
        capacity.concurrency_limit(),
        projected_concurrency,
    )?;
    Ok(Admission {
        demand,
        projected_capacity,
    })
}

fn check_health(provider: &ProviderSnapshot, kind: AdmissionKind) -> Result<(), AdmissionError> {
    match (provider.health().mode(), kind) {
        (HealthMode::Closed { .. }, AdmissionKind::Regular) => Ok(()),
        (HealthMode::HalfOpen { probe: Some(claim) }, AdmissionKind::Probe(supplied))
            if claim.permit_id() == supplied =>
        {
            Ok(())
        }
        (HealthMode::HalfOpen { probe: Some(_) }, AdmissionKind::Probe(_)) => {
            Err(AdmissionError::ProbePermitMismatch)
        }
        _ => Err(AdmissionError::ProviderUnhealthy),
    }
}

/// Deterministic admission rejection.
#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum AdmissionError {
    /// Trait and capacity paths must use one identical context-token count.
    #[error("request traits use {traits:?} context tokens but demand uses {demand:?}")]
    ContextTokenMismatch {
        /// Token count checked by compatibility.
        traits: TokenCount,
        /// Prompt plus maximum completion checked by capacity.
        demand: TokenCount,
    },
    /// Prompt plus completion overflowed.
    #[error(transparent)]
    ResourceArithmetic(#[from] ResourceArithmeticError),
    /// Provider traits are incompatible with the request.
    #[error(transparent)]
    Compatibility(#[from] CompatibilityError),
    /// Circuit state does not admit this traffic class.
    #[error("provider circuit does not admit this traffic")]
    ProviderUnhealthy,
    /// The supplied probe permit is not the sole claimed permit.
    #[error("half-open probe permit does not match")]
    ProbePermitMismatch,
    /// Total token budget would be exceeded.
    #[error(
        "token budget exceeded: capacity {capacity:?}, in use {in_use:?}, requested {requested:?}"
    )]
    TokenBudgetExceeded {
        /// Total budget.
        capacity: TokenCount,
        /// Existing reservation.
        in_use: TokenCount,
        /// New request.
        requested: TokenCount,
    },
    /// KV-cache budget would be exceeded.
    #[error(
        "KV budget exceeded: capacity {capacity:?}, in use {in_use:?}, requested {requested:?}"
    )]
    KvBudgetExceeded {
        /// Total KV bytes.
        capacity: KvBytes,
        /// Existing KV reservation.
        in_use: KvBytes,
        /// New request.
        requested: KvBytes,
    },
    /// Concurrency limit would be exceeded.
    #[error("concurrency exceeded: limit {limit}, in use {in_use}")]
    ConcurrencyExceeded {
        /// Provider limit.
        limit: u32,
        /// Current use.
        in_use: u32,
    },
    /// Incrementing concurrency would wrap.
    #[error("concurrency counter overflow")]
    ConcurrencyOverflow,
    /// Projected capacity failed validation.
    #[error(transparent)]
    Capacity(#[from] CapacityError),
}
