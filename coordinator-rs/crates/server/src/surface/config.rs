use std::{collections::BTreeSet, fmt, fs, path::PathBuf, sync::Arc, time::Duration};

use thiserror::Error;
use url::Url;

use super::{
    billing::StripeSettings,
    identity::{BoundedRateConfig, IdentitySurfaceConfig, PrivyVerifierConfig},
    operations::{
        AdminOtpConfig, DatadogTelemetrySettings, EnrollmentConfig, StateExportConfig,
        TelemetrySettings,
    },
};

const DEFAULT_PUBLIC_BASE_URL: &str = "https://api.darkbloom.dev";
const DEFAULT_MODEL_CDN_URL: &str = "https://models.darkbloom.ai";
const DEFAULT_RELEASE_CDN_URL: &str = "https://api.darkbloom.dev";
const DEFAULT_CONSOLE_URL: &str = "https://console.darkbloom.dev";
const DEFAULT_STATE_ROOT: &str = "/mnt/disks/userdata";
const MAX_RUNTIME_MANIFEST_BYTES: usize = 1024 * 1024;
type EnvLookup<'a> = dyn Fn(&str) -> Option<String> + 'a;

/// Validated production-surface configuration. Secret-bearing fields are never
/// exposed through `Debug`.
#[derive(Clone)]
pub struct FullSurfaceConfig {
    pub enabled: bool,
    pub privy: PrivyVerifierConfig,
    pub identity: IdentitySurfaceConfig,
    pub rates: BoundedRateConfig,
    pub admin_key: Arc<str>,
    pub read_only_key: Arc<str>,
    pub release_key: Arc<str>,
    pub mdm_webhook_secret: Arc<str>,
    pub publishing_enabled: bool,
    pub stripe: Option<StripeSettings>,
    pub public_base_url: Url,
    pub model_cdn_url: Url,
    pub release_cdn_url: Url,
    pub provider_version: Arc<str>,
    pub runtime_manifest: Option<serde_json::Value>,
    pub enrollment: Option<EnrollmentConfig>,
    pub require_enrollment: bool,
    pub state_export: Option<StateExportConfig>,
    pub admin_otp: Option<AdminOtpConfig>,
    pub telemetry: TelemetrySettings,
}

impl fmt::Debug for FullSurfaceConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("FullSurfaceConfig")
            .field("enabled", &self.enabled)
            .field("privy", &self.privy)
            .field("identity", &self.identity)
            .field("rates", &self.rates)
            .field("admin_key_configured", &!self.admin_key.is_empty())
            .field("read_only_key_configured", &!self.read_only_key.is_empty())
            .field("release_key_configured", &!self.release_key.is_empty())
            .field(
                "mdm_webhook_secret_configured",
                &!self.mdm_webhook_secret.is_empty(),
            )
            .field("publishing_enabled", &self.publishing_enabled)
            .field("stripe_configured", &self.stripe.is_some())
            .field("public_base_url", &self.public_base_url)
            .field("model_cdn_url", &self.model_cdn_url)
            .field("release_cdn_url", &self.release_cdn_url)
            .field("provider_version", &self.provider_version)
            .field(
                "runtime_manifest_configured",
                &self.runtime_manifest.is_some(),
            )
            .field("enrollment_configured", &self.enrollment.is_some())
            .field("require_enrollment", &self.require_enrollment)
            .field("state_export_configured", &self.state_export.is_some())
            .field("admin_otp_configured", &self.admin_otp.is_some())
            .field("telemetry", &self.telemetry)
            .finish()
    }
}

impl FullSurfaceConfig {
    pub fn disabled() -> Self {
        let jwks_url =
            Url::parse("https://auth.privy.io/api/v1/apps/disabled/jwks.json").expect("static URL");
        Self {
            enabled: false,
            privy: PrivyVerifierConfig::production("disabled", jwks_url),
            identity: IdentitySurfaceConfig::default(),
            rates: BoundedRateConfig::default(),
            admin_key: Arc::from(""),
            read_only_key: Arc::from(""),
            release_key: Arc::from(""),
            mdm_webhook_secret: Arc::from(""),
            publishing_enabled: false,
            stripe: None,
            public_base_url: Url::parse(DEFAULT_PUBLIC_BASE_URL).expect("static URL"),
            model_cdn_url: Url::parse(DEFAULT_MODEL_CDN_URL).expect("static URL"),
            release_cdn_url: Url::parse(DEFAULT_RELEASE_CDN_URL).expect("static URL"),
            provider_version: Arc::from(""),
            runtime_manifest: None,
            enrollment: None,
            require_enrollment: false,
            state_export: None,
            admin_otp: None,
            telemetry: TelemetrySettings::default(),
        }
    }

    pub fn from_env() -> Result<Self, FullSurfaceConfigError> {
        Self::from_lookup(&|name| std::env::var(name).ok())
    }

    fn from_lookup(lookup: &EnvLookup<'_>) -> Result<Self, FullSurfaceConfigError> {
        if !env_bool(lookup, "EIGENINFERENCE_RUST_FULL_SURFACE_ENABLED", false)? {
            return Ok(Self::disabled());
        }

        let app_id = required(lookup, "EIGENINFERENCE_PRIVY_APP_ID")?;
        let jwks_url = optional(lookup, "EIGENINFERENCE_PRIVY_JWKS_URL")
            .unwrap_or_else(|| format!("https://auth.privy.io/api/v1/apps/{app_id}/jwks.json"));
        let public_base_url = origin(
            "EIGENINFERENCE_BASE_URL",
            optional(lookup, "EIGENINFERENCE_BASE_URL").as_deref(),
            DEFAULT_PUBLIC_BASE_URL,
        )?;
        let model_cdn_url = origin(
            "MODEL_REGISTRY_CDN_BASE_URL",
            optional(lookup, "MODEL_REGISTRY_CDN_BASE_URL").as_deref(),
            DEFAULT_MODEL_CDN_URL,
        )?;
        let release_cdn_url = origin(
            "EIGENINFERENCE_R2_CDN_URL",
            optional(lookup, "EIGENINFERENCE_R2_CDN_URL").as_deref(),
            DEFAULT_RELEASE_CDN_URL,
        )?;
        let console_url = origin(
            "EIGENINFERENCE_CONSOLE_URL",
            optional(lookup, "EIGENINFERENCE_CONSOLE_URL").as_deref(),
            DEFAULT_CONSOLE_URL,
        )?;
        let provider_version =
            optional(lookup, "EIGENINFERENCE_PROVIDER_VERSION").unwrap_or_else(|| "dev".to_owned());

        let mut config = Self {
            enabled: true,
            privy: PrivyVerifierConfig::production(
                app_id,
                Url::parse(&jwks_url).map_err(|_| {
                    FullSurfaceConfigError::InvalidUrl("EIGENINFERENCE_PRIVY_JWKS_URL")
                })?,
            ),
            identity: IdentitySurfaceConfig {
                console_url: Arc::from(console_url.as_str().trim_end_matches('/')),
                latest_provider_version: Arc::from(provider_version.clone()),
                minimum_provider_version: Arc::from(
                    optional(lookup, "EIGENINFERENCE_MIN_PROVIDER_VERSION").unwrap_or_default(),
                ),
                ..IdentitySurfaceConfig::default()
            },
            rates: BoundedRateConfig::default(),
            admin_key: Arc::from(required(lookup, "EIGENINFERENCE_ADMIN_KEY")?),
            read_only_key: Arc::from(required(lookup, "EIGENINFERENCE_READ_ONLY_KEY")?),
            release_key: Arc::from(required(lookup, "EIGENINFERENCE_RELEASE_KEY")?),
            mdm_webhook_secret: Arc::from(required(lookup, "EIGENINFERENCE_MDM_WEBHOOK_SECRET")?),
            publishing_enabled: env_bool(lookup, "MODEL_REGISTRY_PUBLISHING_ENABLED", true)?,
            stripe: stripe_settings(lookup)?,
            public_base_url,
            model_cdn_url,
            release_cdn_url,
            provider_version: Arc::from(provider_version),
            runtime_manifest: optional_json(lookup, "EIGENINFERENCE_RUNTIME_MANIFEST_JSON")?,
            enrollment: None,
            require_enrollment: env_bool(lookup, "EIGENINFERENCE_RUST_REQUIRE_ENROLLMENT", false)?,
            state_export: None,
            admin_otp: None,
            telemetry: telemetry_settings(lookup)?,
        };
        config.rates.maximum_identities = env_usize(
            lookup,
            "EIGENINFERENCE_RUST_RATE_LIMIT_IDENTITIES",
            config.rates.maximum_identities,
            1,
            1_000_000,
        )?;
        config.identity.trusted_proxy_cidrs =
            trusted_proxy_cidrs(lookup, Arc::clone(&config.identity.trusted_proxy_cidrs))?;
        config.enrollment = enrollment_config(lookup)?;
        if config.require_enrollment && config.enrollment.is_none() {
            return Err(FullSurfaceConfigError::Missing(
                "EIGENINFERENCE_RUST_ENROLLMENT_ENABLED",
            ));
        }
        config.state_export = state_export_config(lookup)?;
        config.admin_otp = admin_otp_config(lookup)?;
        Ok(config)
    }
}

fn trusted_proxy_cidrs(
    lookup: &EnvLookup<'_>,
    default: Arc<[ipnet::IpNet]>,
) -> Result<Arc<[ipnet::IpNet]>, FullSurfaceConfigError> {
    const NAME: &str = "EIGENINFERENCE_RUST_TRUSTED_PROXY_CIDRS";
    const MAX_CIDRS: usize = 32;
    const MAX_BYTES: usize = 2048;
    let Some(value) = optional(lookup, NAME) else {
        return Ok(default);
    };
    if value.len() > MAX_BYTES {
        return Err(FullSurfaceConfigError::InvalidNetwork(NAME));
    }
    let cidrs = value
        .split(',')
        .map(str::trim)
        .map(|value| {
            if value.is_empty() {
                return Err(FullSurfaceConfigError::InvalidNetwork(NAME));
            }
            value
                .parse()
                .map_err(|_| FullSurfaceConfigError::InvalidNetwork(NAME))
        })
        .collect::<Result<Vec<_>, _>>()?;
    if cidrs.is_empty() || cidrs.len() > MAX_CIDRS {
        return Err(FullSurfaceConfigError::InvalidNetwork(NAME));
    }
    Ok(cidrs.into())
}

fn telemetry_settings(lookup: &EnvLookup<'_>) -> Result<TelemetrySettings, FullSurfaceConfigError> {
    let mut settings = TelemetrySettings::default();
    settings.persistent_capacity = u32::try_from(env_u64(
        lookup,
        "EIGENINFERENCE_RUST_TELEMETRY_CAPACITY",
        u64::from(settings.persistent_capacity),
        1,
        1_000_000,
    )?)
    .map_err(|_| FullSurfaceConfigError::InvalidNumber("EIGENINFERENCE_RUST_TELEMETRY_CAPACITY"))?;
    settings.maximum_delivery_attempts = u32::try_from(env_u64(
        lookup,
        "EIGENINFERENCE_RUST_TELEMETRY_MAX_ATTEMPTS",
        u64::from(settings.maximum_delivery_attempts),
        1,
        100,
    )?)
    .map_err(|_| {
        FullSurfaceConfigError::InvalidNumber("EIGENINFERENCE_RUST_TELEMETRY_MAX_ATTEMPTS")
    })?;
    settings.request_timeout = Duration::from_secs(env_u64(
        lookup,
        "EIGENINFERENCE_RUST_EXTERNAL_HTTP_TIMEOUT_SECONDS",
        settings.request_timeout.as_secs(),
        1,
        30,
    )?);
    let Some(api_key) = optional(lookup, "DD_API_KEY") else {
        return Ok(settings);
    };
    let site = optional(lookup, "DD_SITE").unwrap_or_else(|| "datadoghq.com".to_owned());
    if site.is_empty()
        || site.len() > 253
        || !site
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-'))
    {
        return Err(FullSurfaceConfigError::InvalidUrl("DD_SITE"));
    }
    let logs_url = Url::parse(&format!("https://http-intake.logs.{site}/api/v2/logs"))
        .map_err(|_| FullSurfaceConfigError::InvalidUrl("DD_SITE"))?;
    settings.datadog = Some(DatadogTelemetrySettings {
        api_key: Arc::from(api_key),
        logs_url,
        environment: Arc::from(
            optional(lookup, "DD_ENV").unwrap_or_else(|| "production".to_owned()),
        ),
        service: Arc::from(
            optional(lookup, "DD_SERVICE").unwrap_or_else(|| "d-inference-coordinator".to_owned()),
        ),
    });
    settings
        .validate()
        .map_err(|_| FullSurfaceConfigError::InvalidTelemetry)?;
    Ok(settings)
}

fn stripe_settings(
    lookup: &EnvLookup<'_>,
) -> Result<Option<StripeSettings>, FullSurfaceConfigError> {
    if !env_bool(lookup, "EIGENINFERENCE_RUST_STRIPE_ENABLED", false)? {
        reject_partial(
            lookup,
            "EIGENINFERENCE_RUST_STRIPE_ENABLED",
            &[
                "EIGENINFERENCE_STRIPE_SECRET_KEY",
                "EIGENINFERENCE_STRIPE_WEBHOOK_SECRET",
                "EIGENINFERENCE_STRIPE_CONNECT_WEBHOOK_SECRET",
            ],
        )?;
        return Ok(None);
    }
    let mut settings = StripeSettings::production(
        required(lookup, "EIGENINFERENCE_STRIPE_SECRET_KEY")?,
        required(lookup, "EIGENINFERENCE_STRIPE_WEBHOOK_SECRET")?,
        required(lookup, "EIGENINFERENCE_STRIPE_CONNECT_WEBHOOK_SECRET")?,
    );
    settings.checkout_success_url =
        Arc::from(required(lookup, "EIGENINFERENCE_STRIPE_SUCCESS_URL")?);
    settings.checkout_cancel_url = Arc::from(required(lookup, "EIGENINFERENCE_STRIPE_CANCEL_URL")?);
    settings.connect_return_url = Arc::from(required(
        lookup,
        "EIGENINFERENCE_STRIPE_CONNECT_RETURN_URL",
    )?);
    settings.connect_refresh_url = Arc::from(required(
        lookup,
        "EIGENINFERENCE_STRIPE_CONNECT_REFRESH_URL",
    )?);
    settings.platform_country = Arc::from(
        optional(lookup, "EIGENINFERENCE_STRIPE_CONNECT_COUNTRY")
            .unwrap_or_else(|| "US".to_owned()),
    );
    settings.request_timeout = Duration::from_secs(env_u64(
        lookup,
        "EIGENINFERENCE_RUST_EXTERNAL_HTTP_TIMEOUT_SECONDS",
        10,
        1,
        30,
    )?);
    Ok(Some(settings))
}

fn enrollment_config(
    lookup: &EnvLookup<'_>,
) -> Result<Option<EnrollmentConfig>, FullSurfaceConfigError> {
    if !env_bool(lookup, "EIGENINFERENCE_RUST_ENROLLMENT_ENABLED", false)? {
        reject_partial(
            lookup,
            "EIGENINFERENCE_RUST_ENROLLMENT_ENABLED",
            &[
                "EIGENINFERENCE_MDM_TOPIC",
                "EIGENINFERENCE_SCEP_CHALLENGE",
                "EIGENINFERENCE_PROFILE_SIGNING_CERT_PEM",
                "EIGENINFERENCE_PROFILE_SIGNING_CERT_FILE",
                "EIGENINFERENCE_PROFILE_SIGNING_KEY_PEM",
                "EIGENINFERENCE_PROFILE_SIGNING_KEY_FILE",
            ],
        )?;
        return Ok(None);
    }
    let certificate = secret_or_file(
        lookup,
        "EIGENINFERENCE_PROFILE_SIGNING_CERT_PEM",
        "EIGENINFERENCE_PROFILE_SIGNING_CERT_FILE",
    )?;
    let private_key = secret_or_file(
        lookup,
        "EIGENINFERENCE_PROFILE_SIGNING_KEY_PEM",
        "EIGENINFERENCE_PROFILE_SIGNING_KEY_FILE",
    )?;
    EnrollmentConfig::cms(
        required(lookup, "EIGENINFERENCE_MDM_TOPIC")?,
        required(lookup, "EIGENINFERENCE_SCEP_CHALLENGE")?,
        certificate,
        private_key,
    )
    .map(Some)
    .map_err(|_| FullSurfaceConfigError::InvalidSigningConfiguration)
}

fn state_export_config(
    lookup: &EnvLookup<'_>,
) -> Result<Option<StateExportConfig>, FullSurfaceConfigError> {
    if !env_bool(lookup, "EIGENINFERENCE_STATE_EXPORT_ENABLED", false)? {
        reject_partial(
            lookup,
            "EIGENINFERENCE_STATE_EXPORT_ENABLED",
            &[
                "EIGENINFERENCE_RUST_STATE_EXPORT_RECIPIENT_X25519",
                "EIGENINFERENCE_RUST_STATE_EXPORT_RECIPIENT_KEY_ID",
            ],
        )?;
        return Ok(None);
    }
    let root = optional(lookup, "EIGENINFERENCE_STATE_EXPORT_ROOT")
        .or_else(|| optional(lookup, "USER_PERSISTENT_DATA_PATH"))
        .unwrap_or_else(|| DEFAULT_STATE_ROOT.to_owned());
    StateExportConfig::encrypted(
        PathBuf::from(root),
        required(lookup, "EIGENINFERENCE_RUST_STATE_EXPORT_RECIPIENT_KEY_ID")?,
        &required(lookup, "EIGENINFERENCE_RUST_STATE_EXPORT_RECIPIENT_X25519")?,
    )
    .map(Some)
    .map_err(|_| FullSurfaceConfigError::InvalidStateExport)
}

fn admin_otp_config(
    lookup: &EnvLookup<'_>,
) -> Result<Option<AdminOtpConfig>, FullSurfaceConfigError> {
    if !env_bool(lookup, "EIGENINFERENCE_RUST_ADMIN_OTP_ENABLED", false)? {
        reject_partial(
            lookup,
            "EIGENINFERENCE_RUST_ADMIN_OTP_ENABLED",
            &[
                "EIGENINFERENCE_PRIVY_APP_SECRET",
                "EIGENINFERENCE_ADMIN_EMAILS",
            ],
        )?;
        return Ok(None);
    }
    let emails = required(lookup, "EIGENINFERENCE_ADMIN_EMAILS")?
        .split(',')
        .map(str::trim)
        .filter(|email| !email.is_empty())
        .map(|email| Arc::<str>::from(email.to_ascii_lowercase()))
        .collect::<BTreeSet<_>>();
    AdminOtpConfig::privy(
        required(lookup, "EIGENINFERENCE_PRIVY_APP_ID")?,
        required(lookup, "EIGENINFERENCE_PRIVY_APP_SECRET")?,
        emails,
    )
    .map(Some)
    .map_err(|_| FullSurfaceConfigError::InvalidAdminOtp)
}

fn secret_or_file(
    lookup: &EnvLookup<'_>,
    value_name: &'static str,
    file_name: &'static str,
) -> Result<String, FullSurfaceConfigError> {
    match (optional(lookup, value_name), optional(lookup, file_name)) {
        (Some(_), Some(_)) => Err(FullSurfaceConfigError::Conflicting(value_name, file_name)),
        (Some(value), None) => Ok(value),
        (None, Some(path)) => fs::read_to_string(path)
            .map_err(|_| FullSurfaceConfigError::UnreadableSecretFile(file_name))
            .and_then(|value| {
                (!value.is_empty())
                    .then_some(value)
                    .ok_or(FullSurfaceConfigError::Missing(value_name))
            }),
        (None, None) => Err(FullSurfaceConfigError::Missing(value_name)),
    }
}

fn reject_partial(
    lookup: &EnvLookup<'_>,
    feature: &'static str,
    names: &[&'static str],
) -> Result<(), FullSurfaceConfigError> {
    if names.iter().any(|name| optional(lookup, name).is_some()) {
        Err(FullSurfaceConfigError::FeatureDisabledWithConfiguration(
            feature,
        ))
    } else {
        Ok(())
    }
}

fn required(lookup: &EnvLookup<'_>, name: &'static str) -> Result<String, FullSurfaceConfigError> {
    optional(lookup, name).ok_or(FullSurfaceConfigError::Missing(name))
}

fn optional(lookup: &EnvLookup<'_>, name: &str) -> Option<String> {
    lookup(name).filter(|value| !value.is_empty())
}

fn env_bool(
    lookup: &EnvLookup<'_>,
    name: &'static str,
    default: bool,
) -> Result<bool, FullSurfaceConfigError> {
    match optional(lookup, name).as_deref() {
        None => Ok(default),
        Some("true") => Ok(true),
        Some("false") => Ok(false),
        Some(_) => Err(FullSurfaceConfigError::InvalidBoolean(name)),
    }
}

fn env_u64(
    lookup: &EnvLookup<'_>,
    name: &'static str,
    default: u64,
    minimum: u64,
    maximum: u64,
) -> Result<u64, FullSurfaceConfigError> {
    let Some(value) = optional(lookup, name) else {
        return Ok(default);
    };
    value
        .parse()
        .ok()
        .filter(|value| (minimum..=maximum).contains(value))
        .ok_or(FullSurfaceConfigError::InvalidNumber(name))
}

fn env_usize(
    lookup: &EnvLookup<'_>,
    name: &'static str,
    default: usize,
    minimum: usize,
    maximum: usize,
) -> Result<usize, FullSurfaceConfigError> {
    let value = env_u64(lookup, name, default as u64, minimum as u64, maximum as u64)?;
    usize::try_from(value).map_err(|_| FullSurfaceConfigError::InvalidNumber(name))
}

fn origin(
    name: &'static str,
    value: Option<&str>,
    default: &'static str,
) -> Result<Url, FullSurfaceConfigError> {
    let url = Url::parse(value.unwrap_or(default))
        .map_err(|_| FullSurfaceConfigError::InvalidUrl(name))?;
    if url.cannot_be_a_base()
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || url.path() != "/"
        || (url.scheme() != "https"
            && !(url.scheme() == "http"
                && url
                    .host_str()
                    .is_some_and(|host| matches!(host, "localhost" | "127.0.0.1"))))
    {
        return Err(FullSurfaceConfigError::InvalidUrl(name));
    }
    Ok(url)
}

fn optional_json(
    lookup: &EnvLookup<'_>,
    name: &'static str,
) -> Result<Option<serde_json::Value>, FullSurfaceConfigError> {
    optional(lookup, name)
        .map(|encoded| {
            if encoded.len() > MAX_RUNTIME_MANIFEST_BYTES {
                return Err(FullSurfaceConfigError::InvalidJson(name));
            }
            serde_json::from_str::<serde_json::Value>(&encoded)
                .ok()
                .filter(serde_json::Value::is_object)
                .ok_or(FullSurfaceConfigError::InvalidJson(name))
        })
        .transpose()
}

#[derive(Debug, Error)]
pub enum FullSurfaceConfigError {
    #[error("missing required full-surface environment variable {0}")]
    Missing(&'static str),
    #[error("invalid boolean in full-surface environment variable {0}")]
    InvalidBoolean(&'static str),
    #[error("invalid bounded number in full-surface environment variable {0}")]
    InvalidNumber(&'static str),
    #[error("invalid URL in full-surface environment variable {0}")]
    InvalidUrl(&'static str),
    #[error("invalid JSON in full-surface environment variable {0}")]
    InvalidJson(&'static str),
    #[error("invalid network list in full-surface environment variable {0}")]
    InvalidNetwork(&'static str),
    #[error("feature {0} is disabled but related configuration is present")]
    FeatureDisabledWithConfiguration(&'static str),
    #[error("conflicting secret value and file environment variables {0} and {1}")]
    Conflicting(&'static str, &'static str),
    #[error("could not read secret file configured by {0}")]
    UnreadableSecretFile(&'static str),
    #[error("invalid enrollment signing configuration")]
    InvalidSigningConfiguration,
    #[error("invalid state export configuration")]
    InvalidStateExport,
    #[error("invalid administrator OTP configuration")]
    InvalidAdminOtp,
    #[error("invalid durable telemetry configuration")]
    InvalidTelemetry,
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::{FullSurfaceConfig, FullSurfaceConfigError};

    #[test]
    fn disabled_surface_does_not_require_production_secrets() {
        let values = BTreeMap::new();
        let config = FullSurfaceConfig::from_lookup(&lookup(&values)).expect("disabled config");
        assert!(!config.enabled);
    }

    #[test]
    fn enabled_surface_requires_every_independent_auth_secret_and_redacts_them() {
        let mut values = required_values();
        values.remove("EIGENINFERENCE_RELEASE_KEY");
        assert!(matches!(
            FullSurfaceConfig::from_lookup(&lookup(&values)),
            Err(FullSurfaceConfigError::Missing(
                "EIGENINFERENCE_RELEASE_KEY"
            ))
        ));

        values.insert("EIGENINFERENCE_RELEASE_KEY", "release-super-secret");
        let config = FullSurfaceConfig::from_lookup(&lookup(&values)).expect("full config");
        let debug = format!("{config:?}");
        for secret in [
            "admin-super-secret",
            "release-super-secret",
            "mdm-super-secret",
        ] {
            assert!(!debug.contains(secret), "Debug disclosed {secret}");
        }
    }

    #[test]
    fn optional_features_reject_partial_or_incomplete_secret_configuration() {
        let mut values = required_values();
        values.insert("EIGENINFERENCE_STRIPE_SECRET_KEY", "sk_test");
        assert!(matches!(
            FullSurfaceConfig::from_lookup(&lookup(&values)),
            Err(FullSurfaceConfigError::FeatureDisabledWithConfiguration(
                "EIGENINFERENCE_RUST_STRIPE_ENABLED"
            ))
        ));

        values.insert("EIGENINFERENCE_RUST_STRIPE_ENABLED", "true");
        assert!(matches!(
            FullSurfaceConfig::from_lookup(&lookup(&values)),
            Err(FullSurfaceConfigError::Missing(
                "EIGENINFERENCE_STRIPE_WEBHOOK_SECRET"
            ))
        ));
    }

    #[test]
    fn production_origins_and_bounds_are_validated_before_startup() {
        let mut values = required_values();
        values.insert("EIGENINFERENCE_BASE_URL", "http://coordinator.example");
        assert!(matches!(
            FullSurfaceConfig::from_lookup(&lookup(&values)),
            Err(FullSurfaceConfigError::InvalidUrl(
                "EIGENINFERENCE_BASE_URL"
            ))
        ));

        values.insert("EIGENINFERENCE_BASE_URL", "https://coordinator.example");
        values.insert("EIGENINFERENCE_RUST_RATE_LIMIT_IDENTITIES", "0");
        assert!(matches!(
            FullSurfaceConfig::from_lookup(&lookup(&values)),
            Err(FullSurfaceConfigError::InvalidNumber(
                "EIGENINFERENCE_RUST_RATE_LIMIT_IDENTITIES"
            ))
        ));

        values.remove("EIGENINFERENCE_RUST_RATE_LIMIT_IDENTITIES");
        values.insert(
            "EIGENINFERENCE_RUST_TRUSTED_PROXY_CIDRS",
            "127.0.0.0/8,not-a-network",
        );
        assert!(matches!(
            FullSurfaceConfig::from_lookup(&lookup(&values)),
            Err(FullSurfaceConfigError::InvalidNetwork(
                "EIGENINFERENCE_RUST_TRUSTED_PROXY_CIDRS"
            ))
        ));

        values.insert(
            "EIGENINFERENCE_RUST_TRUSTED_PROXY_CIDRS",
            "127.0.0.0/8,10.0.0.0/8",
        );
        let config =
            FullSurfaceConfig::from_lookup(&lookup(&values)).expect("valid trusted proxy networks");
        assert_eq!(config.identity.trusted_proxy_cidrs.len(), 2);
    }

    fn required_values() -> BTreeMap<&'static str, &'static str> {
        BTreeMap::from([
            ("EIGENINFERENCE_RUST_FULL_SURFACE_ENABLED", "true"),
            ("EIGENINFERENCE_PRIVY_APP_ID", "test-privy-app"),
            ("EIGENINFERENCE_ADMIN_KEY", "admin-super-secret"),
            ("EIGENINFERENCE_READ_ONLY_KEY", "read-only-super-secret"),
            ("EIGENINFERENCE_RELEASE_KEY", "release-super-secret"),
            ("EIGENINFERENCE_MDM_WEBHOOK_SECRET", "mdm-super-secret"),
        ])
    }

    fn lookup<'a>(
        values: &'a BTreeMap<&'static str, &'static str>,
    ) -> impl Fn(&str) -> Option<String> + 'a {
        |name| values.get(name).map(|value| (*value).to_owned())
    }
}
