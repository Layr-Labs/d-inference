use std::time::Duration;

use super::super::{
    BoundedRateConfig, BoundedRateLimiter, IdentityError, RateClass, RateLimitHook, RateRule,
};

#[test]
fn bounded_rate_limiter_enforces_rules_and_cardinality() {
    let rule = RateRule {
        maximum_requests: 1,
        window: Duration::from_secs(60),
    };
    let limiter = BoundedRateLimiter::new(BoundedRateConfig {
        maximum_identities: 2,
        financial: rule,
        device_code: rule,
        device_poll: rule,
        device_approve: rule,
    })
    .expect("valid bounded rate configuration");

    limiter
        .check(RateClass::Financial, "account-a")
        .expect("first financial request");
    assert!(matches!(
        limiter.check(RateClass::Financial, "account-a"),
        Err(IdentityError::RateLimited(_))
    ));

    limiter
        .check(RateClass::DevicePoll, "device-a")
        .expect("second bounded bucket");
    assert!(
        matches!(
            limiter.check(RateClass::DeviceCode, "client-b"),
            Err(IdentityError::RateLimited(_))
        ),
        "the limiter exceeded its configured cardinality bound"
    );
}

#[test]
fn bounded_rate_limiter_rejects_unbounded_configuration() {
    let invalid_rule = RateRule {
        maximum_requests: 0,
        window: Duration::from_secs(60),
    };
    assert!(matches!(
        BoundedRateLimiter::new(BoundedRateConfig {
            maximum_identities: 1,
            financial: invalid_rule,
            device_code: invalid_rule,
            device_poll: invalid_rule,
            device_approve: invalid_rule,
        }),
        Err(IdentityError::Unavailable)
    ));
}
