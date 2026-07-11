use std::{fmt, sync::Arc};

use darkbloom_coordinator_core::ids::Digest;
use serde_json::Value;
use sha2::{Digest as _, Sha256};
use thiserror::Error;
use uuid::Uuid;

const MAX_TEXT_KEY_BYTES: usize = 256;

macro_rules! uuid_id {
    ($(#[$meta:meta])* $name:ident, $label:literal) => {
        $(#[$meta])*
        #[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
        pub struct $name(Uuid);

        impl $name {
            pub fn new(value: Uuid) -> Result<Self, InputError> {
                if value.is_nil() {
                    Err(InputError::NilId($label))
                } else {
                    Ok(Self(value))
                }
            }

            #[must_use]
            pub fn random() -> Self {
                Self(Uuid::new_v4())
            }

            #[must_use]
            pub const fn as_uuid(self) -> Uuid {
                self.0
            }
        }

        impl TryFrom<Uuid> for $name {
            type Error = InputError;

            fn try_from(value: Uuid) -> Result<Self, Self::Error> {
                Self::new(value)
            }
        }

        impl From<$name> for Uuid {
            fn from(value: $name) -> Self {
                value.0
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                self.0.fmt(formatter)
            }
        }
    };
}

macro_rules! text_id {
    ($(#[$meta:meta])* $name:ident, $label:literal) => {
        $(#[$meta])*
        #[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
        pub struct $name(Arc<str>);

        impl $name {
            pub fn new(value: impl Into<Arc<str>>) -> Result<Self, InputError> {
                let value = value.into();
                validate_text(&value, $label)?;
                Ok(Self(value))
            }

            #[must_use]
            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                self.0.fmt(formatter)
            }
        }
    };
}

uuid_id!(JobId, "job id");
uuid_id!(ReservationId, "reservation id");
uuid_id!(OperationId, "operation id");
uuid_id!(AttemptId, "attempt id");
uuid_id!(TerminalId, "terminal id");
uuid_id!(ExternalEventId, "external event id");
uuid_id!(OutboxId, "outbox id");

text_id!(AccountId, "account id");
text_id!(OperationKey, "operation key");
text_id!(WithdrawalId, "withdrawal id");
text_id!(ExternalId, "external id");

fn validate_text(value: &str, label: &'static str) -> Result<(), InputError> {
    if value.is_empty() {
        return Err(InputError::Empty(label));
    }
    if value.trim() != value {
        return Err(InputError::SurroundingWhitespace(label));
    }
    if value.len() > MAX_TEXT_KEY_BYTES {
        return Err(InputError::TooLong {
            field: label,
            maximum: MAX_TEXT_KEY_BYTES,
        });
    }
    if value.chars().any(char::is_control) {
        return Err(InputError::ControlCharacter(label));
    }
    Ok(())
}

/// A nonnegative amount constrained to PostgreSQL's signed `BIGINT` range.
#[derive(Clone, Copy, Debug, Default, Eq, Ord, PartialEq, PartialOrd)]
pub struct LedgerAmount(i64);

impl LedgerAmount {
    pub const ZERO: Self = Self(0);

    pub fn new(value: u64) -> Result<Self, InputError> {
        i64::try_from(value)
            .map(Self)
            .map_err(|_| InputError::ArithmeticOverflow)
    }

    pub fn from_i64(value: i64) -> Result<Self, InputError> {
        if value < 0 {
            Err(InputError::NegativeAmount)
        } else {
            Ok(Self(value))
        }
    }

    #[must_use]
    pub const fn as_i64(self) -> i64 {
        self.0
    }

    pub fn checked_add(self, other: Self) -> Result<Self, InputError> {
        self.0
            .checked_add(other.0)
            .map(Self)
            .ok_or(InputError::ArithmeticOverflow)
    }

    pub fn checked_sub(self, other: Self) -> Result<Self, InputError> {
        self.0
            .checked_sub(other.0)
            .filter(|value| *value >= 0)
            .map(Self)
            .ok_or(InputError::ArithmeticUnderflow)
    }
}

/// A positive compare-and-swap revision.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct Version(i64);

impl Version {
    pub fn new(value: u64) -> Result<Self, InputError> {
        let value = i64::try_from(value).map_err(|_| InputError::ArithmeticOverflow)?;
        if value == 0 {
            Err(InputError::ZeroVersion)
        } else {
            Ok(Self(value))
        }
    }

    pub(crate) fn from_database(value: i64) -> Result<Self, LedgerError> {
        if value <= 0 {
            Err(LedgerError::CorruptData("nonpositive stored version"))
        } else {
            Ok(Self(value))
        }
    }

    #[must_use]
    pub const fn as_i64(self) -> i64 {
        self.0
    }
}

/// Immutable operation identity used for replay and ambiguous-commit recovery.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Operation {
    pub id: OperationId,
    pub key: OperationKey,
    pub digest: Digest,
}

impl Operation {
    pub fn new(key: OperationKey, digest: Digest) -> Self {
        Self {
            id: OperationId::random(),
            key,
            digest,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MutationDisposition {
    Applied,
    Replayed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum JobState {
    Reserved,
    Preparing,
    Prepared,
    StartAuthorized,
    Running,
    Settled,
    Released,
    ReviewPending,
    SettledReviewed,
    ReleasedReviewed,
}

impl JobState {
    #[must_use]
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Reserved => "reserved",
            Self::Preparing => "preparing",
            Self::Prepared => "prepared",
            Self::StartAuthorized => "start_authorized",
            Self::Running => "running",
            Self::Settled => "settled",
            Self::Released => "released",
            Self::ReviewPending => "review_pending",
            Self::SettledReviewed => "settled_reviewed",
            Self::ReleasedReviewed => "released_reviewed",
        }
    }

    pub(crate) fn from_database(value: &str) -> Result<Self, LedgerError> {
        match value {
            "reserved" => Ok(Self::Reserved),
            "preparing" => Ok(Self::Preparing),
            "prepared" => Ok(Self::Prepared),
            "start_authorized" => Ok(Self::StartAuthorized),
            "running" => Ok(Self::Running),
            "settled" => Ok(Self::Settled),
            "released" => Ok(Self::Released),
            "review_pending" => Ok(Self::ReviewPending),
            "settled_reviewed" => Ok(Self::SettledReviewed),
            "released_reviewed" => Ok(Self::ReleasedReviewed),
            _ => Err(LedgerError::CorruptData("unknown stored job state")),
        }
    }
}

#[derive(Clone, Debug)]
pub struct ReserveRequest {
    pub operation: Operation,
    pub job_id: JobId,
    pub request_id: Uuid,
    pub reservation_id: ReservationId,
    pub account_id: AccountId,
    pub api_key_id: Arc<str>,
    pub amount: LedgerAmount,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ReservationResult {
    pub disposition: MutationDisposition,
    pub job_id: JobId,
    pub version: Version,
    pub total: LedgerAmount,
    pub withdrawable: LedgerAmount,
    pub state: JobState,
}

#[derive(Clone, Debug)]
pub struct PreparedReservation {
    pub operation: Operation,
    pub job_id: JobId,
    pub expected_version: Version,
    pub expected_state: JobState,
    pub attempt_id: AttemptId,
    pub provider_id: Uuid,
    pub provider_process_generation_id: Uuid,
    pub session_epoch: Version,
    pub lease_id: Uuid,
    pub permit_id: Uuid,
    pub dispatch_nonce: Digest,
    pub request_digest: Digest,
    pub concrete_model: Arc<str>,
    pub public_model: Arc<str>,
    pub pricing_version: Version,
    pub rounding_version: Version,
    pub billable_input_tokens: u64,
    pub bounded_output_tokens: u64,
    pub input_micro_usd_per_million: LedgerAmount,
    pub output_micro_usd_per_million: LedgerAmount,
    pub provider_account_id: AccountId,
    pub platform_account_id: AccountId,
    pub referral_account_id: Option<AccountId>,
    pub maximum_provider_payout: LedgerAmount,
    pub maximum_platform_fee: LedgerAmount,
    pub maximum_referral_reward: LedgerAmount,
    pub referral_share_ppm: u32,
}

impl PreparedReservation {
    pub fn maximum_charge(&self) -> Result<LedgerAmount, InputError> {
        self.maximum_provider_payout
            .checked_add(self.maximum_platform_fee)?
            .checked_add(self.maximum_referral_reward)
    }

    pub(crate) fn validate(&self) -> Result<(), InputError> {
        validate_text(&self.concrete_model, "concrete model")?;
        validate_text(&self.public_model, "public model")?;
        if self.provider_id.is_nil()
            || self.provider_process_generation_id.is_nil()
            || self.lease_id.is_nil()
            || self.permit_id.is_nil()
        {
            return Err(InputError::NilId("prepared provider fact"));
        }
        if self.billable_input_tokens > i64::MAX as u64
            || self.bounded_output_tokens > i64::MAX as u64
        {
            return Err(InputError::ArithmeticOverflow);
        }
        if self.referral_share_ppm > 1_000_000 {
            return Err(InputError::InvalidReferralShare);
        }
        match (
            &self.referral_account_id,
            self.maximum_referral_reward.as_i64(),
        ) {
            (None, 0) if self.referral_share_ppm == 0 => {}
            (Some(_), _) => {}
            _ => return Err(InputError::InvalidReferralTerms),
        }
        let maximum_gross_fee = self
            .maximum_platform_fee
            .checked_add(self.maximum_referral_reward)?;
        if proportional_amount(maximum_gross_fee, self.referral_share_ppm)?
            != self.maximum_referral_reward
        {
            return Err(InputError::InvalidReferralTerms);
        }
        let priced_maximum =
            priced_tokens(self.billable_input_tokens, self.input_micro_usd_per_million)?
                .checked_add(priced_tokens(
                    self.bounded_output_tokens,
                    self.output_micro_usd_per_million,
                )?)?;
        if priced_maximum != self.maximum_charge()? {
            return Err(InputError::AllocationMismatch);
        }
        Ok(())
    }
}

fn proportional_amount(total: LedgerAmount, share_ppm: u32) -> Result<LedgerAmount, InputError> {
    let scaled = u128::from(total.as_i64() as u64)
        .checked_mul(u128::from(share_ppm))
        .ok_or(InputError::ArithmeticOverflow)?
        / 1_000_000;
    LedgerAmount::new(u64::try_from(scaled).map_err(|_| InputError::ArithmeticOverflow)?)
}

pub(crate) fn priced_tokens(tokens: u64, rate: LedgerAmount) -> Result<LedgerAmount, InputError> {
    let numerator = u128::from(tokens)
        .checked_mul(rate.as_i64() as u128)
        .ok_or(InputError::ArithmeticOverflow)?;
    let rounded = numerator
        .checked_add(999_999)
        .ok_or(InputError::ArithmeticOverflow)?
        / 1_000_000;
    LedgerAmount::new(u64::try_from(rounded).map_err(|_| InputError::ArithmeticOverflow)?)
}

pub(crate) fn json_digest(value: &Value) -> Result<Digest, LedgerError> {
    let encoded = serde_json::to_vec(value)
        .map_err(|_| LedgerError::CorruptData("JSON payload could not be serialized"))?;
    Ok(Digest::new(Sha256::digest(encoded).into()))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TerminalOutcome {
    Completed,
    Cancelled,
    Error,
}

impl TerminalOutcome {
    #[must_use]
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Completed => "completed",
            Self::Cancelled => "cancelled",
            Self::Error => "error",
        }
    }

    pub(crate) fn from_database(value: &str) -> Result<Self, LedgerError> {
        match value {
            "completed" => Ok(Self::Completed),
            "cancelled" => Ok(Self::Cancelled),
            "error" => Ok(Self::Error),
            _ => Err(LedgerError::CorruptData("unknown stored terminal outcome")),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TerminalLeaseToken {
    pub worker_id: Uuid,
    pub version: Version,
}

#[derive(Clone, Debug)]
pub struct TerminalFacts {
    pub terminal_id: TerminalId,
    pub attempt_id: AttemptId,
    pub provider_id: Uuid,
    pub provider_process_generation_id: Uuid,
    pub origin_session_epoch: Version,
    pub terminal_digest: Digest,
    pub raw_terminal: Value,
    pub outcome: TerminalOutcome,
    pub error_class: Option<Arc<str>>,
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
    pub reasoning_tokens: u64,
    pub response_digest: Digest,
    pub rolling_digest: Digest,
    pub final_generated_tokens: u64,
    pub provider_signature: Vec<u8>,
    pub recovery_lease: Option<TerminalLeaseToken>,
}

#[derive(Clone, Debug)]
pub struct SettleRequest {
    pub operation: Operation,
    pub job_id: JobId,
    pub expected_job_version: Version,
    pub expected_job_state: JobState,
    pub expected_attempt_version: Version,
    pub terminal: TerminalFacts,
    pub consumer_charge: LedgerAmount,
    pub provider_payout: LedgerAmount,
    pub platform_fee: LedgerAmount,
    pub referral_reward: LedgerAmount,
    pub consumer_key_hash: Arc<str>,
}

impl SettleRequest {
    pub(crate) fn validate(&self) -> Result<(), InputError> {
        if self.terminal.provider_id.is_nil()
            || self.terminal.provider_process_generation_id.is_nil()
        {
            return Err(InputError::NilId("terminal provider fact"));
        }
        if !self.terminal.raw_terminal.is_object() {
            return Err(InputError::TerminalPayloadNotObject);
        }
        if self.terminal.provider_signature.is_empty() {
            return Err(InputError::Empty("provider signature"));
        }
        if self
            .terminal
            .recovery_lease
            .as_ref()
            .is_some_and(|lease| lease.worker_id.is_nil())
        {
            return Err(InputError::NilId("terminal recovery worker"));
        }
        for tokens in [
            self.terminal.prompt_tokens,
            self.terminal.completion_tokens,
            self.terminal.reasoning_tokens,
            self.terminal.final_generated_tokens,
        ] {
            if tokens > i64::MAX as u64 {
                return Err(InputError::ArithmeticOverflow);
            }
        }
        if self.terminal.prompt_tokens > i32::MAX as u64
            || self.terminal.completion_tokens > i32::MAX as u64
        {
            return Err(InputError::UsageTokenOverflow);
        }
        validate_text(&self.consumer_key_hash, "consumer key hash")?;
        let allocated = self
            .provider_payout
            .checked_add(self.platform_fee)?
            .checked_add(self.referral_reward)?;
        if allocated != self.consumer_charge {
            return Err(InputError::AllocationMismatch);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SettlementResult {
    pub disposition: MutationDisposition,
    pub job_id: JobId,
    pub version: Version,
    pub charged: LedgerAmount,
    pub charged_withdrawable: LedgerAmount,
    pub refunded: LedgerAmount,
    pub refunded_withdrawable: LedgerAmount,
}

#[derive(Clone, Debug)]
pub struct ReleaseRequest {
    pub operation: Operation,
    pub job_id: JobId,
    pub expected_version: Version,
    pub expected_state: JobState,
    pub reason: Arc<str>,
}

#[derive(Clone, Debug)]
pub struct StripeDeposit {
    pub operation: Operation,
    pub external_event_id: ExternalEventId,
    pub event_id: ExternalId,
    pub checkout_session_id: ExternalId,
    pub billing_session_id: ExternalId,
    pub payload_digest: Digest,
    pub payload: Value,
    pub currency: Arc<str>,
    pub amount: LedgerAmount,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DepositResult {
    pub disposition: MutationDisposition,
    pub account_id: AccountId,
    pub amount: LedgerAmount,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WithdrawalStatus {
    Pending,
    Transferred,
    Paid,
    Failed,
    ReviewPending,
}

impl WithdrawalStatus {
    #[must_use]
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Transferred => "transferred",
            Self::Paid => "paid",
            Self::Failed => "failed",
            Self::ReviewPending => "review_pending",
        }
    }

    pub(crate) fn from_database(value: &str) -> Result<Self, LedgerError> {
        match value {
            "pending" => Ok(Self::Pending),
            "transferred" => Ok(Self::Transferred),
            "paid" => Ok(Self::Paid),
            "failed" => Ok(Self::Failed),
            "review_pending" => Ok(Self::ReviewPending),
            _ => Err(LedgerError::CorruptData("unknown stored withdrawal status")),
        }
    }
}

#[derive(Clone, Debug)]
pub struct WithdrawalRequest {
    pub operation: Operation,
    pub outbox_id: OutboxId,
    pub withdrawal_id: WithdrawalId,
    pub account_id: AccountId,
    pub stripe_account_id: ExternalId,
    pub amount: LedgerAmount,
    pub fee: LedgerAmount,
    pub method: Arc<str>,
    pub external_payload: Value,
}

impl WithdrawalRequest {
    pub fn net(&self) -> Result<LedgerAmount, InputError> {
        self.amount.checked_sub(self.fee)
    }
}

#[derive(Clone, Debug)]
pub struct WithdrawalTransition {
    pub operation: Operation,
    pub withdrawal_id: WithdrawalId,
    pub expected_status: WithdrawalStatus,
    pub transfer_id: Option<ExternalId>,
    pub payout_id: Option<ExternalId>,
    pub sweep_payout_id: Option<ExternalId>,
    pub failure_reason: Option<Arc<str>>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WithdrawalDisposition {
    Applied,
    Replayed,
    ManualReview,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WithdrawalResult {
    pub disposition: WithdrawalDisposition,
    pub status: WithdrawalStatus,
    pub refunded: bool,
}

#[derive(Clone, Debug, Error, Eq, PartialEq)]
pub enum InputError {
    #[error("{0} must not be empty")]
    Empty(&'static str),
    #[error("{0} must not have surrounding whitespace")]
    SurroundingWhitespace(&'static str),
    #[error("{field} exceeds {maximum} bytes")]
    TooLong { field: &'static str, maximum: usize },
    #[error("{0} contains a control character")]
    ControlCharacter(&'static str),
    #[error("{0} must not be the nil UUID")]
    NilId(&'static str),
    #[error("amount must not be negative")]
    NegativeAmount,
    #[error("checked i64 arithmetic overflow")]
    ArithmeticOverflow,
    #[error("checked monetary arithmetic underflow")]
    ArithmeticUnderflow,
    #[error("version must be positive")]
    ZeroVersion,
    #[error("provider, platform, and referral allocations do not equal the charge")]
    AllocationMismatch,
    #[error("referral share exceeds one million ppm")]
    InvalidReferralShare,
    #[error("referral beneficiary and amount terms are inconsistent")]
    InvalidReferralTerms,
    #[error("terminal payload must be a JSON object")]
    TerminalPayloadNotObject,
    #[error("terminal usage exceeds the legacy usage table's integer range")]
    UsageTokenOverflow,
}

#[derive(Debug, Error)]
pub enum LedgerError {
    #[error(transparent)]
    Invalid(#[from] InputError),
    #[error("coordinator ownership is unavailable")]
    OwnershipUnavailable,
    #[error("coordinator ownership was lost")]
    OwnershipLost,
    #[error("immutable operation key or digest conflicts with persisted data")]
    OperationConflict,
    #[error("insufficient account balance")]
    InsufficientBalance,
    #[error("durable record was not found")]
    NotFound,
    #[error("status or version compare-and-swap failed")]
    StaleVersion,
    #[error("database data violates the durable service invariant: {0}")]
    CorruptData(&'static str),
    #[error("PostgreSQL operation failed: {0}")]
    Database(#[source] sqlx::Error),
    #[error("PostgreSQL operation exceeded its deadline")]
    Timeout,
    #[error("commit outcome for operation {0} remains unknown")]
    CommitOutcomeUnknown(OperationKey),
}
