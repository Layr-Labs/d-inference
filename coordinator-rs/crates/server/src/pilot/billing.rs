use std::sync::Arc;

use darkbloom_coordinator_core::ids::Digest;
use darkbloom_coordinator_protocol::v2::ProviderId;
use sha2::{Digest as _, Sha256};
use subtle::{Choice, ConstantTimeEq};
use uuid::Uuid;

use crate::ledger::{
    AccountId, AttemptId, InputError, JobId, LedgerAmount, Operation, OperationKey, ReservationId,
    TerminalId,
};

use super::config::{ConsumerCredentialEntry, PaidBillingPolicy, ProviderBeneficiaryEntry};

const CONSUMER_KEY_DOMAIN: &[u8] = b"darkbloom.rust-pilot.consumer-key.v1\0";
const DERIVED_ID_DOMAIN: &[u8] = b"darkbloom.rust-pilot.derived-id.v1\0";
const OPERATION_DOMAIN: &[u8] = b"darkbloom.rust-pilot.operation.v1\0";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PaidConsumerContext {
    pub account_id: AccountId,
    pub api_key_id: Arc<str>,
    pub consumer_key_hash: Arc<str>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum BillingContext {
    FreeSelfRoute,
    Paid(PaidConsumerContext),
}

impl BillingContext {
    #[must_use]
    pub const fn is_paid(&self) -> bool {
        matches!(self, Self::Paid(_))
    }
}

#[derive(Clone)]
pub struct ConsumerCredential {
    digest: [u8; 32],
    context: BillingContext,
}

impl ConsumerCredential {
    pub fn configured(
        entries: &[ConsumerCredentialEntry],
        paid_mode: bool,
    ) -> Result<Arc<[Self]>, BillingConfigurationError> {
        let mut configured = Vec::with_capacity(entries.len());
        for entry in entries {
            let digest = consumer_key_digest(entry.raw_key.as_bytes());
            if configured
                .iter()
                .any(|existing: &Self| existing.digest == digest)
            {
                return Err(BillingConfigurationError::DuplicateConsumerKey);
            }
            let context = match (&entry.account_id, paid_mode) {
                (_, false) => BillingContext::FreeSelfRoute,
                (Some(account_id), true) => BillingContext::Paid(PaidConsumerContext {
                    account_id: account_id.clone(),
                    api_key_id: entry.api_key_id.clone(),
                    consumer_key_hash: Arc::from(hex_digest(digest)),
                }),
                (None, true) => return Err(BillingConfigurationError::MissingConsumerAccount),
            };
            configured.push(Self { digest, context });
        }
        Ok(configured.into())
    }

    #[must_use]
    pub fn authenticate(configured: &[Self], presented: &str) -> Option<BillingContext> {
        let presented = consumer_key_digest(presented.as_bytes());
        let mut matched = Choice::from(0);
        let mut selected = None;
        for credential in configured {
            let equal = credential.digest.ct_eq(&presented);
            matched |= equal;
            if bool::from(equal) {
                selected = Some(credential.context.clone());
            }
        }
        if bool::from(matched) { selected } else { None }
    }
}

#[derive(Clone)]
pub struct PilotBilling {
    policy: PaidBillingPolicy,
    provider_beneficiaries: Arc<[ProviderBeneficiaryEntry]>,
    provider_price_overrides_enabled: bool,
}

impl PilotBilling {
    pub fn new(
        policy: PaidBillingPolicy,
        provider_beneficiaries: Arc<[ProviderBeneficiaryEntry]>,
    ) -> Result<Self, BillingConfigurationError> {
        for (index, beneficiary) in provider_beneficiaries.iter().enumerate() {
            if provider_beneficiaries[..index]
                .iter()
                .any(|other| other.provider_id == beneficiary.provider_id)
            {
                return Err(BillingConfigurationError::DuplicateProvider);
            }
        }
        Ok(Self {
            policy,
            provider_beneficiaries,
            provider_price_overrides_enabled: true,
        })
    }

    /// Forces every selected provider to use the published platform rates.
    ///
    /// Service and wholesale consumers are sold at the public feed price. A
    /// provider-specific override must therefore never resize their reservation
    /// or settlement charge.
    #[must_use]
    pub fn without_provider_price_overrides(mut self) -> Self {
        self.provider_price_overrides_enabled = false;
        self
    }

    #[must_use]
    pub fn policy(&self) -> &PaidBillingPolicy {
        &self.policy
    }

    #[must_use]
    pub fn provider_account(&self, provider_id: ProviderId) -> Option<&AccountId> {
        self.provider_beneficiaries
            .iter()
            .find(|entry| entry.provider_id == provider_id)
            .map(|entry| &entry.account_id)
    }

    #[must_use]
    pub fn provider_terms(
        &self,
        provider_id: ProviderId,
    ) -> Option<(AccountId, PaidBillingPolicy)> {
        let beneficiary = self
            .provider_beneficiaries
            .iter()
            .find(|entry| entry.provider_id == provider_id)?;
        let mut policy = self.policy.clone();
        if self.provider_price_overrides_enabled
            && let Some(price) = &beneficiary.price_override
        {
            policy.pricing_version = price.pricing_version;
            policy.input_micro_usd_per_million = price.input_micro_usd_per_million;
            policy.output_micro_usd_per_million = price.output_micro_usd_per_million;
        }
        Some((beneficiary.account_id.clone(), policy))
    }

    pub fn amounts(
        &self,
        prompt_tokens: u64,
        completion_tokens: u64,
    ) -> Result<BillingAmounts, InputError> {
        self.policy.amounts(prompt_tokens, completion_tokens)
    }
}

impl PaidBillingPolicy {
    pub fn amounts(
        &self,
        prompt_tokens: u64,
        completion_tokens: u64,
    ) -> Result<BillingAmounts, InputError> {
        let consumer_charge =
            priced_tokens(prompt_tokens, self.input_micro_usd_per_million)?.checked_add(
                priced_tokens(completion_tokens, self.output_micro_usd_per_million)?,
            )?;
        let provider_payout = proportional(consumer_charge, self.provider_share_ppm)?;
        let gross_fee = consumer_charge.checked_sub(provider_payout)?;
        let referral_reward = proportional(gross_fee, self.referral_share_ppm)?;
        let platform_fee = gross_fee.checked_sub(referral_reward)?;
        Ok(BillingAmounts {
            consumer_charge,
            provider_payout,
            platform_fee,
            referral_reward,
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct BillingAmounts {
    pub consumer_charge: LedgerAmount,
    pub provider_payout: LedgerAmount,
    pub platform_fee: LedgerAmount,
    pub referral_reward: LedgerAmount,
}

#[derive(Clone, Debug)]
pub struct DurableRequestIdentity {
    pub request_id: Uuid,
    pub job_id: JobId,
    pub reservation_id: ReservationId,
}

impl DurableRequestIdentity {
    pub fn from_request_id(request_id: Uuid) -> Result<Self, InputError> {
        if request_id.is_nil() {
            return Err(InputError::NilId("request id"));
        }
        Ok(Self {
            request_id,
            job_id: JobId::new(derived_uuid(request_id, "job", &[]))?,
            reservation_id: ReservationId::new(derived_uuid(request_id, "reservation", &[]))?,
        })
    }

    pub fn attempt_id(
        &self,
        ordinal: u8,
        provider_id: ProviderId,
    ) -> Result<AttemptId, InputError> {
        AttemptId::new(derived_uuid(
            self.request_id,
            "attempt",
            &[&[ordinal], provider_id.as_bytes()],
        ))
    }

    pub fn terminal_id(&self, terminal_digest: &[u8; 32]) -> Result<TerminalId, InputError> {
        TerminalId::new(derived_uuid(
            self.request_id,
            "terminal",
            &[terminal_digest],
        ))
    }

    #[must_use]
    pub fn execution_worker_id(&self) -> Uuid {
        derived_uuid(self.request_id, "execution-worker", &[])
    }

    #[must_use]
    pub fn dispatch_nonce(&self, ordinal: u8, provider_id: ProviderId) -> Digest {
        derived_digest(
            self.request_id,
            "dispatch",
            &[&[ordinal], provider_id.as_bytes()],
        )
    }

    pub fn operation(
        &self,
        phase: &str,
        immutable_payload: &[u8],
    ) -> Result<Operation, InputError> {
        let key = OperationKey::new(format!("pilot:{}:{phase}", self.request_id))?;
        let mut hasher = Sha256::new();
        hasher.update(OPERATION_DOMAIN);
        hasher.update(self.request_id.as_bytes());
        hasher.update((phase.len() as u64).to_be_bytes());
        hasher.update(phase.as_bytes());
        hasher.update((immutable_payload.len() as u64).to_be_bytes());
        hasher.update(immutable_payload);
        Ok(Operation::new(key, Digest::new(hasher.finalize().into())))
    }
}

#[must_use]
pub fn request_id_from_idempotency(account_scope: &str, value: &str) -> Uuid {
    derived_uuid(
        Uuid::from_bytes([0x44; 16]),
        "idempotency",
        &[account_scope.as_bytes(), value.as_bytes()],
    )
}

fn consumer_key_digest(key: &[u8]) -> [u8; 32] {
    let mut digest = Sha256::new();
    digest.update(CONSUMER_KEY_DOMAIN);
    digest.update(key);
    digest.finalize().into()
}

fn derived_digest(request_id: Uuid, label: &str, inputs: &[&[u8]]) -> Digest {
    let mut digest = Sha256::new();
    digest.update(DERIVED_ID_DOMAIN);
    digest.update(request_id.as_bytes());
    digest.update((label.len() as u64).to_be_bytes());
    digest.update(label.as_bytes());
    for input in inputs {
        digest.update((input.len() as u64).to_be_bytes());
        digest.update(input);
    }
    Digest::new(digest.finalize().into())
}

fn derived_uuid(request_id: Uuid, label: &str, inputs: &[&[u8]]) -> Uuid {
    let digest = derived_digest(request_id, label, inputs);
    let mut bytes = [0_u8; 16];
    bytes.copy_from_slice(&digest.as_bytes()[..16]);
    // RFC 4122 variant/version bits keep logs and database tooling conventional.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Uuid::from_bytes(bytes)
}

fn priced_tokens(tokens: u64, rate: LedgerAmount) -> Result<LedgerAmount, InputError> {
    let numerator = u128::from(tokens)
        .checked_mul(rate.as_i64() as u128)
        .ok_or(InputError::ArithmeticOverflow)?;
    let rounded = numerator
        .checked_add(999_999)
        .ok_or(InputError::ArithmeticOverflow)?
        / 1_000_000;
    LedgerAmount::new(u64::try_from(rounded).map_err(|_| InputError::ArithmeticOverflow)?)
}

fn proportional(amount: LedgerAmount, share_ppm: u32) -> Result<LedgerAmount, InputError> {
    let value = u128::from(amount.as_i64() as u64)
        .checked_mul(u128::from(share_ppm))
        .ok_or(InputError::ArithmeticOverflow)?
        / 1_000_000;
    LedgerAmount::new(u64::try_from(value).map_err(|_| InputError::ArithmeticOverflow)?)
}

fn hex_digest(digest: [u8; 32]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(64);
    for byte in digest {
        encoded.push(HEX[(byte >> 4) as usize] as char);
        encoded.push(HEX[(byte & 0x0f) as usize] as char);
    }
    encoded
}

#[derive(Clone, Copy, Debug, Eq, thiserror::Error, PartialEq)]
pub enum BillingConfigurationError {
    #[error("pilot consumer API keys must be unique")]
    DuplicateConsumerKey,
    #[error("pilot provider beneficiary mappings must be unique")]
    DuplicateProvider,
    #[error("paid pilot consumer credential is missing an account")]
    MissingConsumerAccount,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn operation_and_ids_are_deterministic_and_phase_separated() {
        let request_id = Uuid::from_bytes([7; 16]);
        let identity = DurableRequestIdentity::from_request_id(request_id).expect("identity");
        let again = DurableRequestIdentity::from_request_id(request_id).expect("identity");
        assert_eq!(identity.job_id, again.job_id);
        assert_eq!(identity.reservation_id, again.reservation_id);
        assert_eq!(identity.execution_worker_id(), again.execution_worker_id());
        assert_ne!(
            identity
                .operation("reserve", b"same")
                .expect("reserve")
                .digest,
            identity
                .operation("settle", b"same")
                .expect("settle")
                .digest
        );
    }

    #[test]
    fn provider_final_generated_is_not_an_amount_input() {
        let billing = PilotBilling::new(
            PaidBillingPolicy {
                platform_account_id: AccountId::new("platform").expect("account"),
                referral_account_id: Some(AccountId::new("referrer").expect("account")),
                pricing_version: crate::ledger::Version::new(1).expect("version"),
                rounding_version: crate::ledger::Version::new(1).expect("version"),
                base_reservation: LedgerAmount::new(1).expect("amount"),
                input_micro_usd_per_million: LedgerAmount::new(1_000_000).expect("amount"),
                output_micro_usd_per_million: LedgerAmount::new(2_000_000).expect("amount"),
                provider_share_ppm: 800_000,
                referral_share_ppm: 100_000,
            },
            Arc::from([]),
        )
        .expect("billing");
        let amounts = billing.amounts(3, 5).expect("amounts");
        assert_eq!(amounts.consumer_charge.as_i64(), 13);
        assert_eq!(
            amounts.provider_payout.as_i64()
                + amounts.platform_fee.as_i64()
                + amounts.referral_reward.as_i64(),
            amounts.consumer_charge.as_i64()
        );
    }

    #[test]
    fn authentication_returns_the_frozen_account_and_key_context() {
        let entries = [ConsumerCredentialEntry {
            raw_key: Arc::from("raw-secret"),
            account_id: Some(AccountId::new("consumer").expect("account")),
            api_key_id: Arc::from("key-id"),
        }];
        let configured = ConsumerCredential::configured(&entries, true).expect("credentials");
        let context =
            ConsumerCredential::authenticate(&configured, "raw-secret").expect("billing context");
        let BillingContext::Paid(context) = context else {
            panic!("paid credential returned a free context");
        };
        assert_eq!(context.account_id.as_str(), "consumer");
        assert_eq!(context.api_key_id.as_ref(), "key-id");
        assert_eq!(context.consumer_key_hash.len(), 64);
        assert_ne!(context.consumer_key_hash.as_ref(), "raw-secret");
        assert_eq!(
            ConsumerCredential::authenticate(&configured, "wrong-secret"),
            None
        );
    }
}
