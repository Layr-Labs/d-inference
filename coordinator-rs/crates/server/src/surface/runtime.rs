use std::sync::Arc;

use thiserror::Error;

use crate::{
    database::Database,
    ownership::FencingContext,
    pilot::{BillingContext, PaidConsumerContext, PilotHandle},
};

use super::{
    FullSurfaceConfig,
    billing::{
        AuthenticationKind, BillingError, BillingPrincipal, BillingState, BillingStateBuilder,
    },
    identity::{
        AuthContext, AuthPrincipal, BoundedRateLimiter, IdentityError, IdentityState,
        MutationAuthority, PrivyVerifier, PrivyVerifierError,
    },
    inference::InferenceControl,
    operations::{
        AdmissionGate, AuthConfigError, ExactBearer, MdmAuth, OperationsAuth, OperationsBuildError,
        OperationsSettings, OperationsState, OperationsStateBuilder, PublicAuth, PublishingAuth,
    },
};

/// All production HTTP domains share this one database, ownership authority,
/// identity service, and live pilot snapshot.
#[derive(Clone)]
pub struct FullSurfaceState {
    pub identity: IdentityState,
    pub billing: BillingState,
    pub operations: Arc<OperationsState>,
    pub pilot: PilotHandle,
    pub(crate) inference_control: InferenceControl,
}

impl FullSurfaceState {
    pub fn build(
        config: &FullSurfaceConfig,
        database: Database,
        authority: &FencingContext,
        pilot: PilotHandle,
    ) -> Result<Self, FullSurfaceBuildError> {
        Self::build_with_admission(config, database, authority, pilot, AdmissionGate::default())
    }

    pub fn build_with_admission(
        config: &FullSurfaceConfig,
        database: Database,
        authority: &FencingContext,
        pilot: PilotHandle,
        admission: AdmissionGate,
    ) -> Result<Self, FullSurfaceBuildError> {
        if !config.enabled {
            return Err(FullSurfaceBuildError::Disabled);
        }
        let mutation_authority = MutationAuthority::new(authority.owner_id(), authority.epoch())
            .ok_or(FullSurfaceBuildError::OwnershipRequired)?;
        let verifier = PrivyVerifier::new(config.privy.clone())?;
        let limiter = Arc::new(BoundedRateLimiter::new(config.rates.clone())?);
        let identity =
            IdentityState::builder(database.pool().clone(), mutation_authority, verifier)
                .config(config.identity.clone())
                .rate_limiter(limiter)
                .pilot(pilot.clone())
                .build()?;

        let mut billing =
            BillingStateBuilder::new(database.clone()).with_admin_key(config.admin_key.clone());
        if let Some(stripe) = config.stripe.clone() {
            billing = billing.with_stripe(stripe);
        }
        let billing = billing.build()?;

        let operations_auth = OperationsAuth {
            public: PublicAuth::Open,
            admin: ExactBearer::required(&config.admin_key)?,
            release: ExactBearer::required(&config.release_key)?,
            publishing: PublishingAuth {
                enabled: config.publishing_enabled,
            },
            mdm: MdmAuth::required(&config.mdm_webhook_secret)?,
        };
        let settings = OperationsSettings {
            public_base_url: config.public_base_url.clone(),
            model_cdn_url: config.model_cdn_url.clone(),
            release_cdn_url: config.release_cdn_url.clone(),
            provider_version: config.provider_version.clone(),
            build_commit: Arc::from(option_env!("DARKBLOOM_BUILD_COMMIT").unwrap_or("unknown")),
            build_date: Arc::from(option_env!("DARKBLOOM_BUILD_DATE").unwrap_or("unknown")),
            runtime_manifest: config.runtime_manifest.clone(),
            owner_epoch: authority.epoch(),
            enrollment: config.enrollment.clone(),
            require_enrollment: config.require_enrollment,
            state_export: config.state_export.clone(),
            admin_otp: config.admin_otp.clone(),
        };
        let inference_control = InferenceControl::new(database.clone());
        let mut operations_builder =
            OperationsStateBuilder::new(database, operations_auth, settings)
                .with_pilot(pilot.clone())
                .with_admission_gate(admission)
                .with_telemetry_settings(config.telemetry.clone());
        if let Some(provider_control) = pilot.provider_control() {
            operations_builder = operations_builder.with_provider_control(provider_control);
        }
        let operations = Arc::new(operations_builder.build()?);
        Ok(Self {
            identity,
            billing,
            operations,
            pilot,
            inference_control,
        })
    }
}

/// Converts the once-resolved identity into the billing extension consumed by
/// every billing handler.
pub fn billing_principal(context: &AuthContext) -> Result<BillingPrincipal, BillingError> {
    let kind = match context.principal {
        AuthPrincipal::Privy { .. } => AuthenticationKind::Privy,
        AuthPrincipal::ApiKey { .. } => AuthenticationKind::ApiKey,
        AuthPrincipal::ProviderToken { .. } => {
            return Err(BillingError::unauthorized(
                "provider credentials cannot authorize billing",
            ));
        }
    };
    BillingPrincipal::new(
        context.account_id.clone(),
        context.email.clone(),
        kind,
        context.role.as_ref() == "admin",
    )
}

/// Free pilot keys are intentionally unavailable in full mode. Every inference
/// request carries durable account and credential provenance.
pub fn durable_billing_context(
    context: &AuthContext,
) -> Result<BillingContext, FullSurfaceBuildError> {
    let account_id = crate::ledger::AccountId::new(context.account_id.to_string())
        .map_err(|_| FullSurfaceBuildError::InvalidAuthenticatedAccount)?;
    let api_key_id: Arc<str> = match (&context.principal, &context.api_key) {
        (AuthPrincipal::ApiKey { key_id }, _) => key_id.clone(),
        (AuthPrincipal::Privy { subject }, _) => {
            let digest = super::identity::hash_secret(subject);
            Arc::from(format!("privy:{}", &digest[..32]))
        }
        (AuthPrincipal::ProviderToken { .. }, _) => {
            return Err(FullSurfaceBuildError::ProviderCannotInfer);
        }
    };
    Ok(BillingContext::Paid(PaidConsumerContext {
        account_id,
        api_key_id,
        consumer_key_hash: context.credential_hash.clone(),
    }))
}

#[derive(Debug, Error)]
pub enum FullSurfaceBuildError {
    #[error("full surface is disabled")]
    Disabled,
    #[error("full surface requires active ownership authority")]
    OwnershipRequired,
    #[error("authenticated account identity is invalid")]
    InvalidAuthenticatedAccount,
    #[error("provider credentials cannot authorize consumer inference")]
    ProviderCannotInfer,
    #[error(transparent)]
    Privy(#[from] PrivyVerifierError),
    #[error(transparent)]
    Identity(#[from] IdentityError),
    #[error(transparent)]
    Billing(#[from] BillingError),
    #[error(transparent)]
    Auth(#[from] AuthConfigError),
    #[error(transparent)]
    Operations(#[from] OperationsBuildError),
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use crate::pilot::BillingContext;

    use super::{
        AuthContext, AuthPrincipal, FullSurfaceBuildError, billing_principal,
        durable_billing_context,
    };

    #[test]
    fn db_identity_maps_to_paid_billing_without_static_credentials() {
        let api_key = context(AuthPrincipal::ApiKey {
            key_id: Arc::from("key-db"),
        });
        let BillingContext::Paid(api_key_billing) =
            durable_billing_context(&api_key).expect("API-key billing context")
        else {
            panic!("full surface must never construct free billing");
        };
        assert_eq!(api_key_billing.account_id.as_str(), "account-db");
        assert_eq!(api_key_billing.api_key_id.as_ref(), "key-db");
        assert_eq!(
            api_key_billing.consumer_key_hash.as_ref(),
            "credential-hash"
        );

        let privy = context(AuthPrincipal::Privy {
            subject: Arc::from("did:privy:test"),
        });
        let BillingContext::Paid(privy_billing) =
            durable_billing_context(&privy).expect("Privy billing context")
        else {
            panic!("full surface must never construct free billing");
        };
        assert_eq!(privy_billing.account_id.as_str(), "account-db");
        assert!(privy_billing.api_key_id.starts_with("privy:"));
        assert_ne!(privy_billing.api_key_id.as_ref(), "did:privy:test");
        assert!(billing_principal(&privy).is_ok());
    }

    #[test]
    fn provider_identity_cannot_cross_authorize_billing_or_inference() {
        let provider = context(AuthPrincipal::ProviderToken {
            label: Arc::from("provider"),
        });
        assert!(billing_principal(&provider).is_err());
        assert!(matches!(
            durable_billing_context(&provider),
            Err(FullSurfaceBuildError::ProviderCannotInfer)
        ));
    }

    fn context(principal: AuthPrincipal) -> AuthContext {
        AuthContext {
            principal,
            account_id: Arc::from("account-db"),
            credential_hash: Arc::from("credential-hash"),
            email: Arc::from("user@example.test"),
            role: Arc::from(""),
            stripe_account_status: Arc::from(""),
            api_key: None,
        }
    }
}
