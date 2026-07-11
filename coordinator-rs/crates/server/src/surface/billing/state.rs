use std::sync::Arc;

use crate::database::Database;

use super::{
    auth::admin_key_digest,
    error::BillingError,
    referral::ReferralService,
    store::BillingStore,
    stripe::{StripeClient, StripeSettings},
};

#[derive(Clone, Debug)]
pub struct BillingState {
    pub(super) store: BillingStore,
    pub(super) stripe: Option<Arc<StripeClient>>,
    pub(super) admin_key_digest: Option<[u8; 32]>,
    pub(super) referral: ReferralService,
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
}

#[derive(Debug)]
pub struct BillingStateBuilder {
    database: Database,
    stripe: Option<StripeSettings>,
    admin_key: Arc<str>,
    referral_share_percent: u32,
}

impl BillingStateBuilder {
    #[must_use]
    pub fn new(database: Database) -> Self {
        Self {
            database,
            stripe: None,
            admin_key: Arc::from(""),
            referral_share_percent: 20,
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

    #[must_use]
    pub fn with_referral_share_percent(mut self, percent: u32) -> Self {
        self.referral_share_percent = percent;
        self
    }

    pub fn build(self) -> Result<BillingState, BillingError> {
        if self.referral_share_percent > 50 {
            return Err(BillingError::bad_request(
                "referral share percent must be between 0 and 50",
            ));
        }
        let store = BillingStore::new(self.database);
        let referral = ReferralService::new(store.clone(), self.referral_share_percent);
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
