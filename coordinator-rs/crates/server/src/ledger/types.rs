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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AttemptState {
    NotSent,
    Queued,
    OnWire,
    SentUnknown,
    Prepared,
    Started,
    TerminalRecorded,
    Aborted,
    Acknowledged,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DurableAttemptKind {
    Primary,
    Alternate,
    Hedge,
}

impl DurableAttemptKind {
    #[must_use]
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Primary => "primary",
            Self::Alternate => "alternate",
            Self::Hedge => "hedge",
        }
    }
}

impl AttemptState {
    #[must_use]
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::NotSent => "not_sent",
            Self::Queued => "queued",
            Self::OnWire => "on_wire",
            Self::SentUnknown => "sent_unknown",
            Self::Prepared => "prepared",
            Self::Started => "started",
            Self::TerminalRecorded => "terminal_recorded",
            Self::Aborted => "aborted",
            Self::Acknowledged => "acknowledged",
        }
    }

    pub(crate) fn from_database(value: &str) -> Result<Self, LedgerError> {
        match value {
            "not_sent" => Ok(Self::NotSent),
            "queued" => Ok(Self::Queued),
            "on_wire" => Ok(Self::OnWire),
            "sent_unknown" => Ok(Self::SentUnknown),
            "prepared" => Ok(Self::Prepared),
            "started" => Ok(Self::Started),
            "terminal_recorded" => Ok(Self::TerminalRecorded),
            "aborted" => Ok(Self::Aborted),
            "acknowledged" => Ok(Self::Acknowledged),
            _ => Err(LedgerError::CorruptData("unknown stored attempt state")),
        }
    }
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
    pub consumer_key_hash: Arc<str>,
    pub amount: LedgerAmount,
    pub request_deadline_epoch_millis: u64,
    pub execution_worker_id: Option<Uuid>,
    pub execution_lease_millis: Option<u64>,
    pub provisional_provider_id: Option<Uuid>,
    pub provisional_session_epoch: Option<Version>,
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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum StartDispatchDisposition {
    Queued,
    OnWire,
    SentUnknown,
    Running,
}

#[derive(Clone, Debug)]
pub struct StartDispatchRequest {
    pub job_id: JobId,
    pub expected_job_version: Version,
    pub expected_job_state: JobState,
    pub attempt_id: AttemptId,
    pub expected_attempt_version: Version,
    pub expected_attempt_state: AttemptState,
    pub disposition: StartDispatchDisposition,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StartDispatchResult {
    pub job_version: Version,
    pub job_state: JobState,
    pub attempt_version: Version,
    pub attempt_state: AttemptState,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DurableTerminalDisposition {
    Settled,
    Released,
    SettledReviewed,
    ReleasedReviewed,
    Late,
    Conflict,
    ReviewPending,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TerminalLookup {
    Absent,
    Known(DurableTerminalDisposition),
    Conflict { job_id: JobId },
}

/// Exact historical attempt identity used for database-authoritative terminal
/// replay. Every field is compared with the durable job/attempt binding before
/// a reviewed disposition can be returned.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DurableAttemptIdentity {
    pub request_id: Uuid,
    pub reservation_id: ReservationId,
    pub attempt_id: AttemptId,
    pub provider_id: Uuid,
    pub provider_process_generation_id: Uuid,
    pub session_epoch: Version,
    pub lease_id: Uuid,
}

impl DurableAttemptIdentity {
    pub(crate) fn validate(self) -> Result<(), InputError> {
        if self.request_id.is_nil()
            || self.provider_id.is_nil()
            || self.provider_process_generation_id.is_nil()
            || self.lease_id.is_nil()
        {
            return Err(InputError::NilId("durable attempt identity"));
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecoveryTerminalRecordResult {
    Pending { job_id: JobId },
    Known(DurableTerminalDisposition),
    Conflict { job_id: JobId },
}

#[derive(Clone, Debug)]
pub struct ReviewRequest {
    pub job_id: JobId,
    pub expected_version: Version,
    pub expected_state: JobState,
    pub provider_id: Uuid,
    pub hard_untrust_epoch: Version,
    pub accepted_cumulative_tokens: u64,
    pub reason: Arc<str>,
    pub evidence_digest: Digest,
}

#[derive(Clone, Debug)]
pub struct AuthorizedTerminalTimeoutRequest {
    pub job_id: JobId,
    pub expected_job_version: Version,
    pub expected_job_state: JobState,
    pub attempt_id: AttemptId,
    pub expected_attempt_version: Version,
}

#[derive(Clone, Debug)]
pub struct PreparedReservation {
    pub operation: Operation,
    pub job_id: JobId,
    pub expected_version: Version,
    pub expected_state: JobState,
    pub attempt_id: AttemptId,
    pub attempt_kind: DurableAttemptKind,
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
    pub provider_share_ppm: u32,
    pub referral_share_ppm: u32,
    pub execution_worker_id: Option<Uuid>,
    pub start_deadline_millis: u64,
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
            || self
                .execution_worker_id
                .is_some_and(|worker| worker.is_nil())
        {
            return Err(InputError::NilId("prepared provider fact"));
        }
        if self.billable_input_tokens > i64::MAX as u64
            || self.bounded_output_tokens > i64::MAX as u64
            || self.start_deadline_millis == 0
            || self.start_deadline_millis > 300_000
        {
            return Err(InputError::ArithmeticOverflow);
        }
        if self.provider_share_ppm > 1_000_000 || self.referral_share_ppm > 1_000_000 {
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
        let maximum_charge = self.maximum_charge()?;
        if proportional_amount(maximum_charge, self.provider_share_ppm)?
            != self.maximum_provider_payout
        {
            return Err(InputError::AllocationMismatch);
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
        if priced_maximum != maximum_charge {
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

/// Hashes a JSON value after recursively sorting object keys. Callers that
/// supply a payload digest must use this representation; insignificant source
/// whitespace and object insertion order therefore cannot alter provenance.
pub fn canonical_json_digest(value: &Value) -> Result<Digest, LedgerError> {
    let mut encoded = Vec::new();
    write_canonical_json(value, &mut encoded)?;
    Ok(Digest::new(Sha256::digest(encoded).into()))
}

fn write_canonical_json(value: &Value, output: &mut Vec<u8>) -> Result<(), LedgerError> {
    match value {
        Value::Null => output.extend_from_slice(b"null"),
        Value::Bool(value) => output.extend_from_slice(if *value { b"true" } else { b"false" }),
        Value::Number(value) => output.extend_from_slice(value.to_string().as_bytes()),
        Value::String(value) => serde_json::to_writer(output, value)
            .map_err(|_| LedgerError::CorruptData("JSON payload could not be serialized"))?,
        Value::Array(values) => {
            output.push(b'[');
            for (index, value) in values.iter().enumerate() {
                if index != 0 {
                    output.push(b',');
                }
                write_canonical_json(value, output)?;
            }
            output.push(b']');
        }
        Value::Object(values) => {
            output.push(b'{');
            let mut fields: Vec<_> = values.iter().collect();
            fields.sort_unstable_by(|left, right| left.0.cmp(right.0));
            for (index, (key, value)) in fields.into_iter().enumerate() {
                if index != 0 {
                    output.push(b',');
                }
                serde_json::to_writer(&mut *output, key).map_err(|_| {
                    LedgerError::CorruptData("JSON payload could not be serialized")
                })?;
                output.push(b':');
                write_canonical_json(value, output)?;
            }
            output.push(b'}');
        }
    }
    Ok(())
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

impl TerminalFacts {
    pub(crate) fn validate(&self) -> Result<(), InputError> {
        if self.provider_id.is_nil() || self.provider_process_generation_id.is_nil() {
            return Err(InputError::NilId("terminal provider fact"));
        }
        if !self.raw_terminal.is_object() {
            return Err(InputError::TerminalPayloadNotObject);
        }
        if self.provider_signature.is_empty() {
            return Err(InputError::Empty("provider signature"));
        }
        if self
            .recovery_lease
            .as_ref()
            .is_some_and(|lease| lease.worker_id.is_nil())
        {
            return Err(InputError::NilId("terminal recovery worker"));
        }
        for tokens in [
            self.prompt_tokens,
            self.completion_tokens,
            self.reasoning_tokens,
            self.final_generated_tokens,
        ] {
            if tokens > i64::MAX as u64 {
                return Err(InputError::ArithmeticOverflow);
            }
        }
        if self.prompt_tokens > i32::MAX as u64 || self.completion_tokens > i32::MAX as u64 {
            return Err(InputError::UsageTokenOverflow);
        }
        Ok(())
    }
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
    pub accepted_cumulative_tokens: u64,
    pub consumer_key_hash: Arc<str>,
    pub review: Option<ReviewResolutionFacts>,
}

impl SettleRequest {
    pub(crate) fn validate(&self) -> Result<(), InputError> {
        self.terminal.validate()?;
        validate_text(&self.consumer_key_hash, "consumer key hash")?;
        let allocated = self
            .provider_payout
            .checked_add(self.platform_fee)?
            .checked_add(self.referral_reward)?;
        if allocated != self.consumer_charge {
            return Err(InputError::AllocationMismatch);
        }
        if self.accepted_cumulative_tokens > i64::MAX as u64 {
            return Err(InputError::ArithmeticOverflow);
        }
        if self.terminal.completion_tokens > self.accepted_cumulative_tokens {
            return Err(InputError::AllocationMismatch);
        }
        if self.terminal.outcome != TerminalOutcome::Completed
            || self.terminal.error_class.is_some()
            || self.terminal.reasoning_tokens > self.terminal.completion_tokens
            || self.terminal.final_generated_tokens != self.terminal.completion_tokens
        {
            return Err(InputError::InvalidTerminalOutcome);
        }
        if self
            .review
            .as_ref()
            .is_some_and(|review| review.operator_reason.is_empty())
        {
            return Err(InputError::Empty("operator review reason"));
        }
        Ok(())
    }
}

#[derive(Clone, Debug)]
pub struct ReviewResolutionFacts {
    pub resolution_id: Uuid,
    pub operator_reason: Arc<str>,
}

#[derive(Clone, Debug)]
pub struct TerminalReleaseRequest {
    pub operation: Operation,
    pub job_id: JobId,
    pub expected_job_version: Version,
    pub expected_job_state: JobState,
    pub expected_attempt_version: Version,
    pub terminal: TerminalFacts,
    pub accepted_cumulative_tokens: u64,
    pub reason: Arc<str>,
}

impl TerminalReleaseRequest {
    pub(crate) fn validate(&self) -> Result<(), InputError> {
        self.terminal.validate()?;
        if !matches!(
            (self.terminal.outcome, self.terminal.error_class.as_deref()),
            (TerminalOutcome::Cancelled, Some("cancelled"))
                | (
                    TerminalOutcome::Error,
                    Some(
                        "invalid_request"
                            | "capacity"
                            | "model_not_ready"
                            | "draining"
                            | "fault"
                            | "security"
                    )
                )
        ) {
            return Err(InputError::InvalidTerminalOutcome);
        }
        if self.accepted_cumulative_tokens > i64::MAX as u64 {
            return Err(InputError::ArithmeticOverflow);
        }
        if self.terminal.reasoning_tokens > self.terminal.completion_tokens
            || self.terminal.final_generated_tokens < self.terminal.completion_tokens
        {
            return Err(InputError::InvalidTerminalUsage);
        }
        validate_text(&self.reason, "terminal release reason")
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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReviewDisposition {
    Settle,
    Release,
}

#[derive(Clone, Debug)]
pub struct ReviewResolutionRequest {
    pub operation: Operation,
    pub job_id: JobId,
    pub disposition: ReviewDisposition,
    pub operator_reason: Arc<str>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ReviewResolutionResult {
    pub disposition: MutationDisposition,
    pub job_id: JobId,
    pub state: JobState,
    pub version: Version,
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
    pub payload_digest: Digest,
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
    #[error("terminal outcome is incompatible with the requested disposition")]
    InvalidTerminalOutcome,
    #[error("terminal usage counters are internally inconsistent")]
    InvalidTerminalUsage,
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
    #[error("provider session is covered by a durable hard-untrust epoch")]
    ProviderHardUntrusted,
    #[error("provider terminal requires durable review: {0}")]
    TerminalReview(&'static str),
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
    #[error("commit outcome for operation {operation} remains unknown: {diagnostic}")]
    CommitOutcomeUnknown {
        operation: OperationKey,
        diagnostic: Arc<str>,
    },
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::canonical_json_digest;

    #[test]
    fn canonical_payload_digest_ignores_object_order_but_not_values() {
        let first = serde_json::from_str(r#"{"z":[3,2,1],"a":{"right":2,"left":1}}"#)
            .expect("first payload");
        let reordered = serde_json::from_str(r#"{ "a": { "left": 1, "right": 2 }, "z": [3,2,1] }"#)
            .expect("reordered payload");
        assert_eq!(
            canonical_json_digest(&first).expect("first digest"),
            canonical_json_digest(&reordered).expect("reordered digest")
        );
        assert_ne!(
            canonical_json_digest(&first).expect("first digest"),
            canonical_json_digest(&json!({
                "a": {"left": 1, "right": 3},
                "z": [3, 2, 1]
            }))
            .expect("changed digest")
        );
    }
}
