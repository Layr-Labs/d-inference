use std::{
    collections::HashMap,
    sync::Mutex,
    time::{Duration, Instant},
};

use super::error::IdentityError;

const MAXIMUM_WINDOW: Duration = Duration::from_secs(24 * 60 * 60);
const MAXIMUM_REQUESTS_PER_WINDOW: u32 = 1_000_000;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum RateClass {
    Financial,
    DeviceCode,
    DevicePoll,
    DeviceApprove,
}

#[derive(Clone, Copy, Debug)]
pub struct RateRule {
    pub maximum_requests: u32,
    pub window: Duration,
}

#[derive(Clone, Debug)]
pub struct BoundedRateConfig {
    pub maximum_identities: usize,
    pub financial: RateRule,
    pub device_code: RateRule,
    pub device_poll: RateRule,
    pub device_approve: RateRule,
}

impl Default for BoundedRateConfig {
    fn default() -> Self {
        Self {
            maximum_identities: 50_000,
            financial: RateRule {
                maximum_requests: 10,
                window: Duration::from_secs(60),
            },
            device_code: RateRule {
                maximum_requests: 10,
                window: Duration::from_secs(60),
            },
            device_poll: RateRule {
                maximum_requests: 30,
                window: Duration::from_secs(60),
            },
            device_approve: RateRule {
                maximum_requests: 10,
                window: Duration::from_secs(60),
            },
        }
    }
}

pub trait RateLimitHook: Send + Sync {
    fn check(&self, class: RateClass, identity: &str) -> Result<(), IdentityError>;
}

#[derive(Debug)]
pub struct BoundedRateLimiter {
    config: BoundedRateConfig,
    buckets: Mutex<HashMap<BucketKey, Bucket>>,
}

impl BoundedRateLimiter {
    pub fn new(config: BoundedRateConfig) -> Result<Self, IdentityError> {
        let rules = [
            config.financial,
            config.device_code,
            config.device_poll,
            config.device_approve,
        ];
        if config.maximum_identities == 0
            || config.maximum_identities > 1_000_000
            || rules.iter().any(|rule| {
                rule.maximum_requests == 0
                    || rule.maximum_requests > MAXIMUM_REQUESTS_PER_WINDOW
                    || rule.window.is_zero()
                    || rule.window > MAXIMUM_WINDOW
            })
        {
            return Err(IdentityError::Unavailable);
        }
        Ok(Self {
            config,
            buckets: Mutex::new(HashMap::new()),
        })
    }

    fn rule(&self, class: RateClass) -> RateRule {
        match class {
            RateClass::Financial => self.config.financial,
            RateClass::DeviceCode => self.config.device_code,
            RateClass::DevicePoll => self.config.device_poll,
            RateClass::DeviceApprove => self.config.device_approve,
        }
    }
}

impl RateLimitHook for BoundedRateLimiter {
    fn check(&self, class: RateClass, identity: &str) -> Result<(), IdentityError> {
        if identity.is_empty() || identity.len() > 256 {
            return Err(IdentityError::Unauthorized);
        }
        let key = BucketKey {
            class,
            identity: identity.to_owned(),
        };
        let now = Instant::now();
        let rule = self.rule(class);
        let mut buckets = self
            .buckets
            .lock()
            .map_err(|_| IdentityError::Unavailable)?;
        if !buckets.contains_key(&key) && buckets.len() >= self.config.maximum_identities {
            buckets.retain(|_, bucket| bucket.reset_at > now);
            if buckets.len() >= self.config.maximum_identities
                && let Some(retry_at) = buckets
                    .iter()
                    .min_by_key(|(_, bucket)| bucket.reset_at)
                    .map(|(_, bucket)| bucket.reset_at)
            {
                return Err(IdentityError::RateLimited(
                    retry_at.saturating_duration_since(now),
                ));
            }
        }
        let bucket = buckets.entry(key).or_insert(Bucket {
            used: 0,
            reset_at: now + rule.window,
        });
        if bucket.reset_at <= now {
            bucket.used = 0;
            bucket.reset_at = now + rule.window;
        }
        if bucket.used >= rule.maximum_requests {
            return Err(IdentityError::RateLimited(
                bucket.reset_at.saturating_duration_since(now),
            ));
        }
        bucket.used += 1;
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct BucketKey {
    class: RateClass,
    identity: String,
}

#[derive(Clone, Copy, Debug)]
struct Bucket {
    used: u32,
    reset_at: Instant,
}
