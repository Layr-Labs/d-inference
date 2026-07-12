//! Durable billing, Stripe, referral, pricing, and invitation HTTP surface.
//!
//! Authentication middleware integrates by inserting [`BillingPrincipal`] in
//! each authenticated request's extensions. Signed Stripe webhook routes do
//! not consume that extension.

mod auth;
mod body;
mod checkout;
mod connect;
mod error;
mod handlers;
mod invite;
mod money;
mod pricing;
mod referral;
mod state;
mod store;
mod stripe;
mod webhook;
mod withdraw;
mod withdrawal_recovery;

use axum::{
    Router,
    routing::{delete, get, post, put},
};

pub use auth::{AuthenticationKind, BillingPrincipal};
pub use error::BillingError;
pub use referral::{ReferralAllocation, ReferralService};
pub use state::{BillingState, BillingStateBuilder};
pub use store::{Balance, BillingSession, Earning, EarningsResponse, UsageEntry, WithdrawalView};
pub use stripe::StripeSettings;
pub use withdrawal_recovery::{
    WithdrawalRecovery, WithdrawalRecoveryAction, WithdrawalRecoveryError,
};

/// Builds the complete Objective 7 surface. The returned router owns
/// [`BillingState`] and can be merged into the coordinator's root router.
pub fn router(state: BillingState) -> Router {
    Router::new()
        .route("/v1/payments/balance", get(handlers::balance))
        .route("/v1/payments/usage", get(handlers::usage))
        .route("/v1/provider/earnings", get(handlers::provider_earnings))
        .route(
            "/v1/provider/account-earnings",
            get(handlers::account_earnings),
        )
        .route("/v1/billing/wallet/balance", get(handlers::balance))
        .route("/v1/billing/methods", get(handlers::methods))
        .route(
            "/v1/billing/stripe/create-session",
            post(checkout::create_session),
        )
        .route("/v1/billing/stripe/webhook", post(checkout::webhook))
        .route("/v1/billing/stripe/session", get(checkout::session_status))
        .route("/v1/billing/stripe/onboard", post(connect::onboard))
        .route("/v1/billing/stripe/status", get(connect::status))
        .route("/v1/billing/withdraw/stripe", post(withdraw::withdraw))
        .route("/v1/billing/stripe/withdrawals", get(connect::withdrawals))
        .route("/v1/billing/stripe/account", delete(connect::unlink))
        .route(
            "/v1/billing/stripe/connect/webhook",
            post(webhook::connect_webhook),
        )
        .route(
            "/v1/pricing",
            get(handlers::pricing_get)
                .put(handlers::pricing_put)
                .delete(handlers::pricing_delete),
        )
        .route("/v1/admin/pricing", put(handlers::admin_pricing_put))
        .route("/v1/referral/register", post(handlers::referral_register))
        .route("/v1/referral/apply", post(handlers::referral_apply))
        .route("/v1/referral/stats", get(handlers::referral_stats))
        .route("/v1/referral/info", get(handlers::referral_info))
        .route(
            "/v1/admin/invite-codes",
            post(handlers::admin_invite_create)
                .get(handlers::admin_invite_list)
                .delete(handlers::admin_invite_delete),
        )
        .route("/v1/invite/redeem", post(handlers::invite_redeem))
        .route("/v1/admin/credit", post(handlers::admin_credit))
        .route("/v1/admin/reward", post(handlers::admin_reward))
        .with_state(state)
}

#[cfg(test)]
mod tests;
