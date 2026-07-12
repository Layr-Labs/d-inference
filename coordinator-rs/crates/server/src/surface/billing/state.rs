use std::sync::Arc;

use crate::database::Database;

use super::{
    auth::admin_key_digest,
    error::BillingError,
    referral::ReferralService,
    store::BillingStore,
    stripe::{StripeClient, StripeSettings},
};

#[derive(Clone)]
pub struct BillingState {
    pub(super) store: BillingStore,
    pub(super) stripe: Option<Arc<StripeClient>>,
    pub(super) admin_key_digest: Option<[u8; 32]>,
    pub(super) referral: ReferralService,
}

impl std::fmt::Debug for BillingState {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("BillingState")
            .field("stripe_configured", &self.stripe.is_some())
            .field("admin_key_configured", &self.admin_key_digest.is_some())
            .finish_non_exhaustive()
    }
}

impl BillingState {
    #[must_use]
    pub fn builder(database: Database) -> BillingStateBuilder {
        BillingStateBuilder::new(database)
    }

    #[must_use]
    pub fn referral_service(&self) -> ReferralService {
        self.referral.clone()
    }

    #[must_use]
    pub fn stripe_configured(&self) -> bool {
        self.stripe.is_some()
    }

    #[must_use]
    pub fn withdrawal_recovery(&self) -> Option<super::WithdrawalRecovery> {
        self.stripe
            .as_ref()
            .map(|stripe| super::WithdrawalRecovery::from_parts(self.store.clone(), stripe.clone()))
    }
}

pub struct BillingStateBuilder {
    database: Database,
    stripe: Option<StripeSettings>,
    admin_key: Arc<str>,
}

impl std::fmt::Debug for BillingStateBuilder {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("BillingStateBuilder")
            .field("stripe_configured", &self.stripe.is_some())
            .field("admin_key_configured", &!self.admin_key.is_empty())
            .finish_non_exhaustive()
    }
}

impl BillingStateBuilder {
    #[must_use]
    pub fn new(database: Database) -> Self {
        Self {
            database,
            stripe: None,
            admin_key: Arc::from(""),
        }
    }

    #[must_use]
    pub fn with_stripe(mut self, stripe: StripeSettings) -> Self {
        self.stripe = Some(stripe);
        self
    }

    #[must_use]
    pub fn with_admin_key(mut self, key: impl Into<Arc<str>>) -> Self {
        self.admin_key = key.into();
        self
    }

    pub fn build(self) -> Result<BillingState, BillingError> {
        let store = BillingStore::new(self.database);
        let referral = ReferralService::new(store.clone());
        Ok(BillingState {
            store,
            stripe: self
                .stripe
                .map(StripeClient::new)
                .transpose()?
                .map(Arc::new),
            admin_key_digest: admin_key_digest(&self.admin_key),
            referral,
        })
    }
}
