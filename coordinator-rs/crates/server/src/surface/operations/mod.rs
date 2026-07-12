//! DB-backed public, trust, release, telemetry, and administrative HTTP surface.
//!
//! This module owns no inference routing policy. Durable catalog and operational
//! reads come from the deployed `public` schema; live capacity and quiescence
//! come from immutable Pilot/Fleet snapshots.

mod admin;
mod admission;
mod auth;
mod error;
mod install;
mod models;
mod public;
mod releases;
mod state_export;
mod telemetry;
mod telemetry_durable;
mod trust;

#[cfg(test)]
mod tests;

use std::{
    collections::{BTreeMap, BTreeSet},
    fmt,
    sync::{Arc, Mutex, atomic::AtomicU64},
    time::Duration,
};

use axum::{
    Router,
    routing::{delete, get, post, put},
};
use sqlx::PgPool;
use thiserror::Error;
use url::Url;

use crate::{database::Database, pilot::PilotHandle, provider_control::ProviderControlPlane};

pub use admission::{AdmissionGate, AdmissionGuard, AdmissionKind, AdmissionRejected};
pub use auth::{
    AuthConfigError, ExactBearer, MdmAuth, OperationsAuth, OperationsPrincipal, PublicAuth,
    PublishingAuth,
};
pub use state_export::StateExportConfig;
pub use telemetry_durable::{
    DatadogTelemetrySettings, TelemetryDeliverySnapshot, TelemetryService, TelemetryServiceError,
    TelemetrySettings,
};
pub use trust::EnrollmentConfig;

use self::{
    auth::AdminSessions,
    telemetry::TelemetryBuffer,
    trust::{MdmCommandExpectation, MdmCommandRegistry},
};

const DEFAULT_OPERATION_TIMEOUT: Duration = Duration::from_secs(10);
const DEFAULT_TELEMETRY_CAPACITY: usize = 4_096;
const MAX_TELEMETRY_CAPACITY: usize = 65_536;

#[derive(Clone, Debug)]
pub struct OperationsSettings {
    pub public_base_url: Url,
    pub model_cdn_url: Url,
    pub release_cdn_url: Url,
    pub provider_version: Arc<str>,
    pub build_commit: Arc<str>,
    pub build_date: Arc<str>,
    pub runtime_manifest: Option<serde_json::Value>,
    pub owner_epoch: i64,
    pub enrollment: Option<EnrollmentConfig>,
    pub require_enrollment: bool,
    pub state_export: Option<StateExportConfig>,
    pub admin_otp: Option<AdminOtpConfig>,
}

#[derive(Clone)]
pub struct AdminOtpConfig {
    pub base_url: Url,
    pub app_id: Arc<str>,
    pub app_secret: Arc<str>,
    pub admin_emails: BTreeSet<Arc<str>>,
    pub request_timeout: Duration,
}

impl fmt::Debug for AdminOtpConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AdminOtpConfig")
            .field("base_url", &self.base_url)
            .field("app_id", &self.app_id)
            .field("app_secret", &"<redacted>")
            .field("admin_emails", &self.admin_emails)
            .field("request_timeout", &self.request_timeout)
            .finish()
    }
}

impl AdminOtpConfig {
    pub fn privy(
        app_id: impl Into<Arc<str>>,
        app_secret: impl Into<Arc<str>>,
        admin_emails: impl IntoIterator<Item = Arc<str>>,
    ) -> Result<Self, OperationsBuildError> {
        let app_id = app_id.into();
        let app_secret = app_secret.into();
        let admin_emails = admin_emails.into_iter().collect::<BTreeSet<_>>();
        if app_id.is_empty() || app_secret.is_empty() || admin_emails.is_empty() {
            return Err(OperationsBuildError::InvalidAdminOtp);
        }
        let config = Self {
            base_url: Url::parse("https://auth.privy.io/api/v1/auth/email/")
                .expect("Privy URL is static and valid"),
            app_id,
            app_secret,
            admin_emails,
            request_timeout: Duration::from_secs(10),
        };
        config.validate()?;
        Ok(config)
    }

    fn validate(&self) -> Result<(), OperationsBuildError> {
        let local_http = self.base_url.scheme() == "http"
            && self
                .base_url
                .host_str()
                .is_some_and(|host| host == "localhost" || host == "127.0.0.1");
        if self.app_id.is_empty()
            || self.app_secret.is_empty()
            || self.admin_emails.is_empty()
            || self.request_timeout.is_zero()
            || self.base_url.cannot_be_a_base()
            || self.base_url.host_str().is_none()
            || !self.base_url.username().is_empty()
            || self.base_url.password().is_some()
            || self.base_url.query().is_some()
            || self.base_url.fragment().is_some()
            || !self.base_url.path().ends_with('/')
            || (self.base_url.scheme() != "https" && !local_http)
            || self.admin_emails.iter().any(|email| {
                email.is_empty()
                    || email.trim() != email.as_ref()
                    || email.chars().any(char::is_control)
            })
        {
            return Err(OperationsBuildError::InvalidAdminOtp);
        }
        Ok(())
    }
}

pub struct OperationsStateBuilder {
    database: Database,
    auth: OperationsAuth,
    settings: OperationsSettings,
    pilot: Option<PilotHandle>,
    provider_control: Option<ProviderControlPlane>,
    admission: AdmissionGate,
    operation_timeout: Duration,
    telemetry_capacity: usize,
    telemetry_settings: TelemetrySettings,
}

impl OperationsStateBuilder {
    #[must_use]
    pub fn new(database: Database, auth: OperationsAuth, settings: OperationsSettings) -> Self {
        Self {
            database,
            auth,
            settings,
            pilot: None,
            provider_control: None,
            admission: AdmissionGate::default(),
            operation_timeout: DEFAULT_OPERATION_TIMEOUT,
            telemetry_capacity: DEFAULT_TELEMETRY_CAPACITY,
            telemetry_settings: TelemetrySettings::default(),
        }
    }

    #[must_use]
    pub fn with_pilot(mut self, pilot: PilotHandle) -> Self {
        self.pilot = Some(pilot);
        self
    }

    #[must_use]
    pub fn with_provider_control(mut self, provider_control: ProviderControlPlane) -> Self {
        self.provider_control = Some(provider_control);
        self
    }

    #[must_use]
    pub fn with_admission_gate(mut self, admission: AdmissionGate) -> Self {
        self.admission = admission;
        self
    }

    #[must_use]
    pub fn with_operation_timeout(mut self, timeout: Duration) -> Self {
        self.operation_timeout = timeout;
        self
    }

    #[must_use]
    pub fn with_telemetry_capacity(mut self, capacity: usize) -> Self {
        self.telemetry_capacity = capacity;
        self
    }

    #[must_use]
    pub fn with_telemetry_settings(mut self, settings: TelemetrySettings) -> Self {
        self.telemetry_settings = settings;
        self
    }

    pub fn build(self) -> Result<OperationsState, OperationsBuildError> {
        if self.operation_timeout.is_zero() {
            return Err(OperationsBuildError::ZeroOperationTimeout);
        }
        if self.telemetry_capacity == 0 || self.telemetry_capacity > MAX_TELEMETRY_CAPACITY {
            return Err(OperationsBuildError::InvalidTelemetryCapacity {
                actual: self.telemetry_capacity,
                maximum: MAX_TELEMETRY_CAPACITY,
            });
        }
        if self.settings.owner_epoch <= 0 {
            return Err(OperationsBuildError::InvalidOwnerEpoch);
        }
        if self.settings.require_enrollment && self.settings.enrollment.is_none() {
            return Err(OperationsBuildError::UnsignedEnrollmentForbidden);
        }
        if let Some(enrollment) = &self.settings.enrollment {
            enrollment.validate()?;
        }
        if let Some(export) = &self.settings.state_export {
            export.validate()?;
        }
        if let Some(admin_otp) = &self.settings.admin_otp {
            admin_otp.validate()?;
        }
        if self
            .settings
            .runtime_manifest
            .as_ref()
            .is_some_and(|manifest| !manifest.is_object())
        {
            return Err(OperationsBuildError::InvalidRuntimeManifest);
        }
        validate_origin(&self.settings.public_base_url)?;
        validate_origin(&self.settings.model_cdn_url)?;
        validate_origin(&self.settings.release_cdn_url)?;
        self.telemetry_settings.validate()?;

        let http_client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(OperationsBuildError::HttpClient)?;
        let telemetry_service =
            TelemetryService::new(self.database.clone(), self.telemetry_settings)?;
        Ok(OperationsState {
            database: self.database,
            auth: self.auth,
            settings: self.settings,
            pilot: self.pilot,
            provider_control: self.provider_control,
            operation_timeout: self.operation_timeout,
            admission: self.admission,
            mutations: AtomicU64::new(0),
            telemetry: TelemetryBuffer::new(self.telemetry_capacity),
            telemetry_service,
            admin_sessions: AdminSessions::default(),
            mdm_commands: MdmCommandRegistry::default(),
            metrics: OperationsMetrics::default(),
            http_client,
        })
    }
}

pub struct OperationsState {
    database: Database,
    auth: OperationsAuth,
    settings: OperationsSettings,
    pilot: Option<PilotHandle>,
    provider_control: Option<ProviderControlPlane>,
    operation_timeout: Duration,
    admission: AdmissionGate,
    mutations: AtomicU64,
    telemetry: TelemetryBuffer,
    telemetry_service: TelemetryService,
    admin_sessions: AdminSessions,
    mdm_commands: MdmCommandRegistry,
    metrics: OperationsMetrics,
    http_client: reqwest::Client,
}

impl OperationsState {
    #[must_use]
    pub fn is_draining(&self) -> bool {
        self.admission.is_draining()
    }

    pub fn set_draining(&self, draining: bool) {
        self.admission.set_draining(draining);
    }

    pub fn begin_handoff(&self) {
        self.admission.begin_handoff();
    }

    #[must_use]
    pub fn mutation_count(&self) -> u64 {
        self.mutations.load(std::sync::atomic::Ordering::Acquire)
    }

    #[must_use]
    pub fn admission_gate(&self) -> AdmissionGate {
        self.admission.clone()
    }

    #[must_use]
    pub fn active_http_inference(&self) -> u64 {
        self.admission.active_inference()
    }

    #[must_use]
    pub fn active_http_mutations(&self) -> u64 {
        self.admission.active_mutations()
    }

    #[must_use]
    pub fn active_external_operations(&self) -> u64 {
        self.admission.active_external()
    }

    #[must_use]
    pub fn telemetry_service(&self) -> TelemetryService {
        self.telemetry_service.clone()
    }

    pub fn expect_mdm_command(
        &self,
        command_uuid: impl Into<Arc<str>>,
        command: impl Into<Arc<str>>,
    ) -> Result<(), OperationsBuildError> {
        self.mdm_commands
            .insert(MdmCommandExpectation {
                command_uuid: command_uuid.into(),
                command: command.into(),
            })
            .map_err(OperationsBuildError::MdmCommand)
    }

    fn pool(&self) -> &PgPool {
        self.database.pool()
    }

    fn pilot(&self) -> Option<&PilotHandle> {
        self.pilot.as_ref()
    }

    fn mark_mutation(&self) {
        self.mutations
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    }
}

#[derive(Default)]
struct OperationsMetrics {
    counters: Mutex<BTreeMap<&'static str, u64>>,
}

impl OperationsMetrics {
    fn increment(&self, name: &'static str) {
        let mut counters = lock(&self.counters);
        let value = counters.entry(name).or_default();
        *value = value.saturating_add(1);
    }

    fn snapshot(&self) -> BTreeMap<&'static str, u64> {
        lock(&self.counters).clone()
    }
}

pub fn router(state: OperationsState) -> Router {
    router_with_state(Arc::new(state))
}

/// Builds the operations router while retaining a shareable state handle for
/// composition roots that need to consult drain state or register MDM commands.
pub fn router_with_state(state: Arc<OperationsState>) -> Router {
    Router::new()
        .route("/install.sh", get(install::install_script))
        .route("/v1/models", get(models::list_models))
        .route("/v1/models/openrouter", get(models::list_openrouter))
        .route("/v1/models/capacity", get(models::model_capacity))
        .route("/v1/models/catalog", get(models::catalog))
        .route(
            "/v1/models/catalog/manifest/{*model_id}",
            get(models::manifest),
        )
        .route("/v1/models/catalog/{*model_id}", get(models::catalog_item))
        .route("/v1/models/{*model_id}", get(models::model_detail))
        .route("/v1/admin/models/register", post(models::register_model))
        .route(
            "/v1/admin/models/aliases",
            get(models::list_aliases).post(models::upsert_alias),
        )
        .route(
            "/v1/admin/models/aliases/{alias_id}",
            delete(models::delete_alias),
        )
        .route(
            "/v1/admin/models/{*action}",
            post(models::admin_model_action),
        )
        .route("/v1/stats", get(public::stats))
        .route("/v1/leaderboard", get(public::leaderboard))
        .route("/v1/network/totals", get(public::network_totals))
        .route("/api/version", get(public::version))
        .route("/v1/releases", post(releases::register_release))
        .route("/v1/releases/latest", get(releases::latest_release))
        .route(
            "/v1/admin/releases",
            get(releases::admin_list).delete(releases::admin_delete),
        )
        .route(
            "/v1/providers/attestation",
            get(trust::provider_attestation),
        )
        .route("/v1/runtime/manifest", get(trust::runtime_manifest))
        .route("/v1/enroll", post(trust::enroll))
        .route("/v1/mdm/webhook", post(trust::mdm_webhook))
        .route("/v1/telemetry/events", post(telemetry::ingest))
        .route(
            "/v1/provider/log-report",
            post(telemetry::upload_log_report),
        )
        .route("/v1/admin/log-reports", get(telemetry::list_log_reports))
        .route("/v1/admin/log-reports/{id}", get(telemetry::get_log_report))
        .route("/v1/admin/users/role", put(admin::set_user_role))
        .route(
            "/v1/admin/users/platform-fee",
            put(admin::set_user_platform_fee),
        )
        .route("/v1/admin/state-export", get(state_export::export))
        .route("/v1/admin/metrics", get(admin::metrics))
        .route("/v1/admin/base-rewards", get(admin::base_rewards))
        .route("/v1/admin/utilization", get(admin::utilization))
        .route("/v1/admin/drain", post(admin::drain))
        .route("/v1/admin/quiescence", get(admin::quiescence))
        .route("/v1/admin/routes", get(admin::routes))
        .route("/v1/admin/routes/export", get(admin::routes_export))
        .route("/v1/admin/rejections", get(admin::rejections))
        .route("/v1/admin/rejections/export", get(admin::rejections_export))
        .route("/v1/admin/auth/init", post(admin::auth_init))
        .route("/v1/admin/auth/verify", post(admin::auth_verify))
        .with_state(state)
}

fn validate_origin(url: &Url) -> Result<(), OperationsBuildError> {
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
                    .is_some_and(|host| host == "localhost" || host == "127.0.0.1")))
    {
        return Err(OperationsBuildError::InvalidOrigin(url.clone()));
    }
    Ok(())
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

#[derive(Debug, Error)]
pub enum OperationsBuildError {
    #[error("operations timeout must be greater than zero")]
    ZeroOperationTimeout,
    #[error("telemetry capacity {actual} is outside 1..={maximum}")]
    InvalidTelemetryCapacity { actual: usize, maximum: usize },
    #[error("external event owner epoch must be positive")]
    InvalidOwnerEpoch,
    #[error("enrollment was required without configured signing materials")]
    UnsignedEnrollmentForbidden,
    #[error("invalid HTTP origin {0}")]
    InvalidOrigin(Url),
    #[error("admin OTP requires app id, app secret, and at least one admin email")]
    InvalidAdminOtp,
    #[error("runtime manifest must be a JSON object")]
    InvalidRuntimeManifest,
    #[error("build bounded operations HTTP client: {0}")]
    HttpClient(reqwest::Error),
    #[error(transparent)]
    Enrollment(#[from] trust::EnrollmentConfigError),
    #[error(transparent)]
    StateExport(#[from] state_export::StateExportConfigError),
    #[error(transparent)]
    Telemetry(#[from] TelemetryServiceError),
    #[error("invalid MDM command expectation: {0}")]
    MdmCommand(Arc<str>),
}
