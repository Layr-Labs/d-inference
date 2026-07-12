//! Durable provider authentication, session persistence, and MDM trust.

use std::{collections::BTreeMap, fmt, sync::Arc, time::Duration};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use darkbloom_coordinator_protocol::{
    v1::{AttestationResponse, Registration},
    v2::{ProviderId, SessionEpoch},
};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};
use sqlx::{FromRow, Row, types::Json as SqlJson};
use subtle::ConstantTimeEq as _;
use thiserror::Error;
use tokio::time::{Instant, sleep};
use url::Url;
use uuid::Uuid;

use crate::{
    crypto::X25519PublicKey,
    database::{Database, DatabaseError},
    ledger::{ExternalEventId, canonical_json_digest},
    recovery::{ExternalDisposition, ExternalEventLease},
    surface::operations::{AdmissionGate, AdmissionKind},
    trust::{P256PublicIdentity, RegistrationTrust},
};

const MAX_TOKEN_BYTES: usize = 4_096;
const MAX_MDM_RESPONSE_BYTES: usize = 256 * 1024;
const MDM_COMMAND_TTL: Duration = Duration::from_secs(30 * 60);
const TRUST_CLOCK_SKEW: Duration = Duration::from_secs(2 * 60);

#[derive(Clone)]
pub struct MdmControlConfig {
    pub base_url: Url,
    pub api_key: Arc<str>,
    pub request_timeout: Duration,
    pub security_info_timeout: Duration,
    pub trust_reuse_window: Duration,
}

impl fmt::Debug for MdmControlConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("MdmControlConfig")
            .field("base_url", &self.base_url)
            .field("api_key", &"<redacted>")
            .field("request_timeout", &self.request_timeout)
            .field("security_info_timeout", &self.security_info_timeout)
            .field("trust_reuse_window", &self.trust_reuse_window)
            .finish()
    }
}

impl MdmControlConfig {
    pub fn validate(&self) -> Result<(), ProviderControlError> {
        let local_http = self.base_url.scheme() == "http"
            && self
                .base_url
                .host_str()
                .is_some_and(|host| matches!(host, "localhost" | "127.0.0.1"));
        if self.api_key.is_empty()
            || self.request_timeout.is_zero()
            || self.request_timeout > Duration::from_secs(30)
            || self.security_info_timeout.is_zero()
            || self.security_info_timeout > MDM_COMMAND_TTL
            || self.trust_reuse_window.is_zero()
            || self.base_url.cannot_be_a_base()
            || self.base_url.host_str().is_none()
            || !self.base_url.username().is_empty()
            || self.base_url.password().is_some()
            || self.base_url.query().is_some()
            || self.base_url.fragment().is_some()
            || (self.base_url.scheme() != "https" && !local_http)
        {
            return Err(ProviderControlError::InvalidMdmConfiguration);
        }
        Ok(())
    }
}

#[derive(Clone)]
pub struct ConfiguredProviderIdentity {
    pub provider_id: ProviderId,
    pub token: Arc<str>,
    pub account_id: Arc<str>,
}

impl fmt::Debug for ConfiguredProviderIdentity {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ConfiguredProviderIdentity")
            .field("provider_id", &self.provider_id)
            .field("token", &"<redacted>")
            .field("account_id", &self.account_id)
            .finish()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CredentialSource {
    Configured,
    DeviceLinked,
}

#[derive(Clone, Debug)]
pub struct AuthenticatedProvider {
    pub provider_id: ProviderId,
    pub account_id: Arc<str>,
    pub token_hash: Arc<str>,
    source: CredentialSource,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct MdmProviderFence {
    pub provider_id: ProviderId,
    pub session_epoch: SessionEpoch,
}

#[derive(Clone)]
pub struct ProviderControlPlane {
    database: Database,
    configured: Arc<BTreeMap<ProviderId, ConfiguredCredential>>,
    mdm: MdmControlConfig,
    client: reqwest::Client,
    admission: Option<AdmissionGate>,
}

#[derive(Clone)]
struct ConfiguredCredential {
    token_hash: Arc<str>,
    account_id: Arc<str>,
}

impl fmt::Debug for ProviderControlPlane {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ProviderControlPlane")
            .field("configured_identities", &self.configured.len())
            .field("mdm", &self.mdm)
            .finish_non_exhaustive()
    }
}

impl ProviderControlPlane {
    pub fn new(
        database: Database,
        configured: impl IntoIterator<Item = ConfiguredProviderIdentity>,
        mdm: MdmControlConfig,
    ) -> Result<Self, ProviderControlError> {
        mdm.validate()?;
        let mut identities = BTreeMap::new();
        let mut token_hashes = BTreeMap::<Arc<str>, ProviderId>::new();
        for identity in configured {
            if identity.token.is_empty()
                || identity.token.len() > MAX_TOKEN_BYTES
                || identity.account_id.is_empty()
                || identities.contains_key(&identity.provider_id)
            {
                return Err(ProviderControlError::InvalidConfiguredCredential);
            }
            let token_hash: Arc<str> = Arc::from(hash_secret(&identity.token));
            if token_hashes
                .insert(token_hash.clone(), identity.provider_id)
                .is_some()
            {
                return Err(ProviderControlError::InvalidConfiguredCredential);
            }
            identities.insert(
                identity.provider_id,
                ConfiguredCredential {
                    token_hash,
                    account_id: identity.account_id,
                },
            );
        }
        let client = reqwest::Client::builder()
            .timeout(mdm.request_timeout)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(ProviderControlError::HttpClient)?;
        Ok(Self {
            database,
            configured: Arc::new(identities),
            mdm,
            client,
            admission: None,
        })
    }

    #[must_use]
    pub fn with_admission_gate(mut self, admission: AdmissionGate) -> Self {
        self.admission = Some(admission);
        self
    }

    pub async fn authenticate(
        &self,
        token: &str,
    ) -> Result<AuthenticatedProvider, ProviderControlError> {
        validate_token(token)?;
        let token_hash: Arc<str> = Arc::from(hash_secret(token));
        let mut configured_match = None;
        for (provider_id, configured) in self.configured.iter() {
            if bool::from(
                configured
                    .token_hash
                    .as_bytes()
                    .ct_eq(token_hash.as_bytes()),
            ) {
                configured_match = Some(AuthenticatedProvider {
                    provider_id: *provider_id,
                    account_id: configured.account_id.clone(),
                    token_hash: token_hash.clone(),
                    source: CredentialSource::Configured,
                });
            }
        }
        if let Some(identity) = configured_match {
            return Ok(identity);
        }

        let candidate = Uuid::new_v4().to_string();
        let mut transaction = self.database.begin_owned().await?;
        let row = sqlx::query_as::<_, ProviderTokenAuthRow>(
            r#"
            WITH locked AS MATERIALIZED (
                SELECT token_hash, account_id, provider_id, active
                FROM public.provider_tokens
                WHERE token_hash = $1
                FOR UPDATE
            ), assigned AS (
                UPDATE public.provider_tokens AS tokens
                SET
                    provider_id = CASE
                        WHEN locked.provider_id = '' THEN $2
                        ELSE locked.provider_id
                    END,
                    updated_at = NOW()
                FROM locked
                WHERE tokens.token_hash = locked.token_hash
                  AND locked.active
                  AND locked.account_id <> ''
                RETURNING
                    tokens.token_hash, tokens.account_id, tokens.provider_id,
                    tokens.active
            )
            SELECT token_hash, account_id, provider_id, active
            FROM assigned
            "#,
        )
        .bind(token_hash.as_ref())
        .bind(candidate)
        .fetch_optional(transaction.connection())
        .await?
        .ok_or(ProviderControlError::InvalidCredential)?;
        transaction.commit().await?;
        if !row.active
            || row.account_id.is_empty()
            || !constant_time_hash_match(&token_hash, &row.token_hash)
        {
            return Err(ProviderControlError::InvalidCredential);
        }
        let provider_uuid =
            Uuid::parse_str(&row.provider_id).map_err(|_| ProviderControlError::CorruptIdentity)?;
        if provider_uuid.is_nil() {
            return Err(ProviderControlError::CorruptIdentity);
        }
        Ok(AuthenticatedProvider {
            provider_id: ProviderId::new(*provider_uuid.as_bytes()),
            account_id: Arc::from(row.account_id),
            token_hash,
            source: CredentialSource::DeviceLinked,
        })
    }

    pub async fn bind_identity(
        &self,
        identity: &AuthenticatedProvider,
        x25519: X25519PublicKey,
        se_key: &P256PublicIdentity,
    ) -> Result<(), ProviderControlError> {
        let provider_id = provider_uuid(identity.provider_id).to_string();
        let x25519 = x25519.to_base64();
        let se_key = se_key.as_base64();
        let mut transaction = self.database.begin_owned().await?;
        if identity.source == CredentialSource::DeviceLinked {
            let bound = sqlx::query(
                r#"
                UPDATE public.provider_tokens
                SET
                    x25519_public_key = CASE
                        WHEN x25519_public_key = '' THEN $3
                        ELSE x25519_public_key
                    END,
                    se_public_key = CASE
                        WHEN se_public_key = '' THEN $4
                        ELSE se_public_key
                    END,
                    updated_at = NOW()
                WHERE token_hash = $1
                  AND provider_id = $2
                  AND active
                  AND (
                      (x25519_public_key = '' AND se_public_key = '')
                      OR (
                          x25519_public_key = $3
                          AND se_public_key = $4
                      )
                  )
                "#,
            )
            .bind(identity.token_hash.as_ref())
            .bind(&provider_id)
            .bind(&x25519)
            .bind(se_key)
            .execute(transaction.connection())
            .await?;
            if bound.rows_affected() != 1 {
                return Err(ProviderControlError::IdentityRotation);
            }
        }
        let provider = sqlx::query(
            r#"
            INSERT INTO public.providers (
                id, hardware, models, backend, account_id, public_key,
                se_public_key, token_hash
            )
            VALUES ($1, '{}'::jsonb, '[]'::jsonb, '', $2, $3, $4, $5)
            ON CONFLICT (id) DO UPDATE SET
                account_id = EXCLUDED.account_id,
                public_key = CASE
                    WHEN providers.public_key = '' THEN EXCLUDED.public_key
                    ELSE providers.public_key
                END,
                se_public_key = CASE
                    WHEN providers.se_public_key = '' THEN EXCLUDED.se_public_key
                    ELSE providers.se_public_key
                END,
                token_hash = EXCLUDED.token_hash
            WHERE providers.account_id IN ('', EXCLUDED.account_id)
              AND providers.public_key IN ('', EXCLUDED.public_key)
              AND providers.se_public_key IN ('', EXCLUDED.se_public_key)
            "#,
        )
        .bind(&provider_id)
        .bind(identity.account_id.as_ref())
        .bind(&x25519)
        .bind(se_key)
        .bind(identity.token_hash.as_ref())
        .execute(transaction.connection())
        .await?;
        if provider.rows_affected() != 1 {
            return Err(ProviderControlError::IdentityRotation);
        }
        transaction.commit().await?;
        Ok(())
    }

    pub async fn establish_hardware_trust(
        &self,
        identity: &AuthenticatedProvider,
        session_epoch: SessionEpoch,
        registration: &RegistrationTrust,
        response: &AttestationResponse,
    ) -> Result<(), ProviderControlError> {
        let serial = registration
            .serial_number
            .as_deref()
            .filter(|serial| valid_identity_text(serial, 128))
            .ok_or(ProviderControlError::MissingSerial)?;
        let binary_hash = normalize_sha256(&response.binary_hash)?;
        if self
            .try_reuse_trust(
                identity.provider_id,
                session_epoch,
                registration.se_public_key.as_base64(),
                serial,
                &binary_hash,
                response,
            )
            .await?
        {
            return Ok(());
        }

        let device = self.lookup_device(serial).await?;
        if device.serial_number != serial || device.udid.is_empty() || !device.enrollment_status {
            return Err(ProviderControlError::DeviceNotEnrolled);
        }
        let command_uuid = Uuid::new_v4().to_string();
        self.persist_mdm_expectation(
            &command_uuid,
            identity.provider_id,
            session_epoch,
            serial,
            &device.udid,
            registration.se_public_key.as_base64(),
            &binary_hash,
            response.sip_enabled == Some(true),
            response.secure_boot_enabled == Some(true),
        )
        .await?;
        if let Err(error) = self.send_security_info(&command_uuid, &device.udid).await {
            self.expire_expectation(&command_uuid, "micromdm command delivery failed")
                .await?;
            return Err(error);
        }
        self.wait_for_mdm_result(&command_uuid).await
    }

    pub async fn provider_is_active(
        &self,
        provider_id: ProviderId,
    ) -> Result<bool, ProviderControlError> {
        if self.configured.contains_key(&provider_id) {
            return Ok(true);
        }
        let provider_id = provider_uuid(provider_id).to_string();
        let active = sqlx::query_scalar::<_, bool>(
            r#"
            SELECT EXISTS (
                SELECT 1
                FROM public.provider_tokens
                WHERE provider_id = $1 AND active
            )
            "#,
        )
        .bind(provider_id)
        .fetch_one(self.database.pool())
        .await?;
        Ok(active)
    }

    pub async fn bound_signing_key(
        &self,
        provider_id: ProviderId,
    ) -> Result<Option<P256PublicIdentity>, ProviderControlError> {
        let encoded = sqlx::query_scalar::<_, String>(
            r#"
            SELECT se_public_key
            FROM public.providers
            WHERE id = $1 AND se_public_key <> ''
            "#,
        )
        .bind(provider_uuid(provider_id).to_string())
        .fetch_optional(self.database.pool())
        .await?;
        encoded
            .map(|encoded| {
                P256PublicIdentity::from_base64(&encoded)
                    .map_err(|_| ProviderControlError::CorruptIdentity)
            })
            .transpose()
    }

    pub async fn persist_connected(
        &self,
        identity: &AuthenticatedProvider,
        registration: &Registration,
        process_generation: Uuid,
        session_epoch: SessionEpoch,
        trust: &RegistrationTrust,
    ) -> Result<(), ProviderControlError> {
        let provider_id = provider_uuid(identity.provider_id).to_string();
        let session_id =
            session_identifier(identity.provider_id, process_generation, session_epoch);
        let hardware = serde_json::to_value(&registration.hardware)?;
        let models = serde_json::to_value(&registration.models)?;
        let serial = trust.serial_number.as_deref().unwrap_or_default();
        let mut transaction = self.database.begin_owned().await?;
        let updated = sqlx::query(
            r#"
            UPDATE public.providers
            SET
                hardware = $2,
                models = $3,
                backend = $4,
                version = $5,
                serial_number = $6,
                account_id = $7,
                token_hash = $8,
                connected = TRUE,
                session_id = $9,
                provider_process_generation = $10,
                session_epoch = $11,
                registered_at = COALESCE(registered_at, NOW()),
                last_seen = NOW(),
                trust_level = 'hardware',
                attested = TRUE,
                last_challenge_verified = NOW()
            WHERE id = $1
              AND public_key = $12
              AND se_public_key = $13
              AND (
                  $15::BOOLEAN
                  OR EXISTS (
                      SELECT 1
                      FROM public.provider_tokens AS tokens
                      WHERE tokens.token_hash = $8
                        AND tokens.provider_id = $1
                        AND tokens.account_id = $7
                        AND tokens.active
                        AND tokens.x25519_public_key = $12
                        AND tokens.se_public_key = $13
                  )
              )
              AND NOT EXISTS (
                  SELECT 1
                  FROM rust_coord.provider_hard_untrust_epochs AS untrusted
                  WHERE untrusted.provider_id = $14
                    AND untrusted.hard_untrust_epoch >= $11
              )
            "#,
        )
        .bind(&provider_id)
        .bind(SqlJson(hardware))
        .bind(SqlJson(models))
        .bind(&registration.backend)
        .bind(&registration.version)
        .bind(serial)
        .bind(identity.account_id.as_ref())
        .bind(identity.token_hash.as_ref())
        .bind(&session_id)
        .bind(process_generation.to_string())
        .bind(epoch_i64(session_epoch)?)
        .bind(&registration.public_key)
        .bind(trust.se_public_key.as_base64())
        .bind(provider_uuid(identity.provider_id))
        .bind(identity.source == CredentialSource::Configured)
        .execute(transaction.connection())
        .await?;
        if updated.rows_affected() != 1 {
            return Err(ProviderControlError::HardUntrusted);
        }
        sqlx::query(
            r#"
            INSERT INTO public.provider_sessions (
                session_id, serial_number, account_id, provider_key
            )
            VALUES ($1, $2, $3, $4)
            ON CONFLICT (session_id) DO UPDATE SET
                last_seen = NOW(),
                disconnected_at = NULL,
                disconnect_reason = ''
            "#,
        )
        .bind(&session_id)
        .bind(serial)
        .bind(identity.account_id.as_ref())
        .bind(&provider_id)
        .execute(transaction.connection())
        .await?;
        transaction.commit().await?;
        Ok(())
    }

    pub async fn persist_heartbeat(
        &self,
        provider_id: ProviderId,
        session_epoch: SessionEpoch,
    ) -> Result<bool, ProviderControlError> {
        let _admission = self
            .admission
            .as_ref()
            .map(|gate| gate.enter(AdmissionKind::Mutation))
            .transpose()
            .map_err(|_| ProviderControlError::Draining)?;
        let configured = self.configured.contains_key(&provider_id);
        let provider_id = provider_uuid(provider_id).to_string();
        let epoch = epoch_i64(session_epoch)?;
        let mut transaction = self.database.begin_owned().await?;
        let authority = transaction.context().clone();
        let (authority_ok, provider_touched, session_touched): (bool, bool, bool) = sqlx::query_as(
            r#"
            WITH authority AS MATERIALIZED (
                SELECT 1
                FROM public.coordinator_ownership
                WHERE singleton = TRUE
                  AND owner_id = $4
                  AND epoch = $5
            ), touched AS (
                UPDATE public.providers AS providers
                SET last_seen = NOW()
                FROM authority
                WHERE providers.id = $1
                  AND providers.connected
                  AND providers.session_epoch = $2
                  AND (
                      $3::BOOLEAN
                      OR EXISTS (
                          SELECT 1
                          FROM public.provider_tokens AS tokens
                          WHERE tokens.provider_id = providers.id
                            AND tokens.token_hash = providers.token_hash
                            AND tokens.account_id = providers.account_id
                            AND tokens.active
                      )
                  )
                RETURNING session_id
            ), session_touched AS (
                UPDATE public.provider_sessions AS sessions
                SET last_seen = NOW()
                FROM touched
                WHERE sessions.session_id = touched.session_id
                RETURNING 1
            )
            SELECT
                EXISTS (SELECT 1 FROM authority),
                EXISTS (SELECT 1 FROM touched),
                EXISTS (SELECT 1 FROM session_touched)
            "#,
        )
        .bind(provider_id)
        .bind(epoch)
        .bind(configured)
        .bind(authority.owner_id())
        .bind(authority.epoch())
        .fetch_one(transaction.connection())
        .await?;
        if !authority_ok {
            return Err(ProviderControlError::OwnershipUnavailable);
        }
        transaction.commit().await?;
        Ok(provider_touched && session_touched)
    }

    pub async fn persist_disconnected(
        &self,
        provider_id: ProviderId,
        session_epoch: SessionEpoch,
        reason: &str,
    ) -> Result<(), ProviderControlError> {
        let provider_id = provider_uuid(provider_id).to_string();
        let epoch = epoch_i64(session_epoch)?;
        let reason = bounded_reason(reason);
        let mut transaction = self.database.begin_owned().await?;
        let session_id: Option<String> = sqlx::query_scalar(
            r#"
            UPDATE public.providers
            SET connected = FALSE, last_seen = NOW()
            WHERE id = $1 AND session_epoch = $2
            RETURNING session_id
            "#,
        )
        .bind(&provider_id)
        .bind(epoch)
        .fetch_optional(transaction.connection())
        .await?;
        if let Some(session_id) = session_id {
            sqlx::query(
                r#"
                UPDATE public.provider_sessions
                SET
                    last_seen = NOW(),
                    disconnected_at = COALESCE(disconnected_at, NOW()),
                    disconnect_reason = $2
                WHERE session_id = $1
                "#,
            )
            .bind(session_id)
            .bind(reason)
            .execute(transaction.connection())
            .await?;
        }
        transaction.commit().await?;
        Ok(())
    }

    pub async fn ingest_mdm_webhook(
        &self,
        payload: Value,
    ) -> Result<ExternalDisposition, ProviderControlError> {
        let evidence = parse_mdm_evidence(&payload)?;
        let digest = canonical_json_digest(&payload)?;
        let external_event_id = ExternalEventId::new(Uuid::new_v4())
            .map_err(|_| ProviderControlError::CorruptIdentity)?;
        let owner_epoch = self
            .database
            .authority()
            .ok_or(ProviderControlError::OwnershipUnavailable)?
            .0
            .epoch();
        let mut transaction = self.database.begin_owned().await?;
        let inserted = sqlx::query(
            r#"
            INSERT INTO rust_coord.external_events (
                external_event_id, source, event_id, event_kind, payload_digest,
                payload, status, owner_epoch
            )
            VALUES ($1, 'micromdm', $2, 'SecurityInfo', $3, $4, 'pending', $5)
            ON CONFLICT (source, event_id) DO NOTHING
            "#,
        )
        .bind(external_event_id.as_uuid())
        .bind(&evidence.command_uuid)
        .bind(digest.as_bytes().as_slice())
        .bind(SqlJson(payload.clone()))
        .bind(owner_epoch)
        .execute(transaction.connection())
        .await?;
        if inserted.rows_affected() == 0 {
            let row = sqlx::query(
                r#"
                SELECT external_event_id, payload_digest, status
                FROM rust_coord.external_events
                WHERE source = 'micromdm' AND event_id = $1
                "#,
            )
            .bind(&evidence.command_uuid)
            .fetch_one(transaction.connection())
            .await?;
            let stored = row.get::<Vec<u8>, _>("payload_digest");
            if stored.as_slice() != digest.as_bytes() {
                return Err(ProviderControlError::MdmEventConflict);
            }
            transaction.rollback().await?;
            return Ok(disposition_from_status(
                row.get::<String, _>("status").as_str(),
            ));
        }
        transaction.commit().await?;

        let disposition = self.apply_mdm_payload(&payload).await?;
        let status = disposition_status(disposition);
        let mut transaction = self.database.begin_owned().await?;
        sqlx::query(
            r#"
            UPDATE rust_coord.external_events
            SET
                status = $2,
                version = version + 1,
                updated_at = NOW(),
                processed_at = NOW()
            WHERE external_event_id = $1 AND status = 'pending'
            "#,
        )
        .bind(external_event_id.as_uuid())
        .bind(status)
        .execute(transaction.connection())
        .await?;
        transaction.commit().await?;
        Ok(disposition)
    }

    pub async fn recover_mdm_event(
        &self,
        lease: &ExternalEventLease,
    ) -> Result<ExternalDisposition, ProviderControlError> {
        if lease.source.as_ref() != "micromdm" || lease.event_kind.as_ref() != "SecurityInfo" {
            return Ok(ExternalDisposition::Ignored);
        }
        if canonical_json_digest(&lease.payload)? != lease.payload_digest {
            return Ok(ExternalDisposition::Failed);
        }
        self.apply_mdm_payload(&lease.payload).await
    }

    pub async fn mdm_provider_fence(
        &self,
        command_uuid: &str,
    ) -> Result<Option<MdmProviderFence>, ProviderControlError> {
        let row = sqlx::query_as::<_, MdmProviderFenceRow>(
            r#"
            SELECT provider_id, session_epoch
            FROM rust_coord.mdm_command_expectations
            WHERE command_uuid = $1
            "#,
        )
        .bind(command_uuid)
        .fetch_optional(self.database.pool())
        .await?;
        row.map(|row| {
            Ok(MdmProviderFence {
                provider_id: ProviderId::new(*row.provider_id.as_bytes()),
                session_epoch: SessionEpoch(
                    u64::try_from(row.session_epoch)
                        .map_err(|_| ProviderControlError::CorruptMdmState)?,
                ),
            })
        })
        .transpose()
    }

    async fn try_reuse_trust(
        &self,
        provider_id: ProviderId,
        session_epoch: SessionEpoch,
        se_key: &str,
        serial: &str,
        binary_hash: &str,
        response: &AttestationResponse,
    ) -> Result<bool, ProviderControlError> {
        if response.sip_enabled != Some(true) || response.secure_boot_enabled != Some(true) {
            return Ok(false);
        }
        let reuse_seconds = i64::try_from(self.mdm.trust_reuse_window.as_secs())
            .map_err(|_| ProviderControlError::InvalidMdmConfiguration)?;
        let skew_seconds = i64::try_from(TRUST_CLOCK_SKEW.as_secs())
            .map_err(|_| ProviderControlError::InvalidMdmConfiguration)?;
        let row = sqlx::query_scalar::<_, bool>(
            r#"
            SELECT EXISTS (
                SELECT 1
                FROM public.provider_trust_reuse AS reuse
                WHERE reuse.se_pubkey = $1
                  AND reuse.provider_id = $2
                  AND reuse.serial = $3
                  AND reuse.binary_hash = $4
                  AND reuse.trust_level = 'hardware'
                  AND reuse.sip_enabled
                  AND reuse.secure_boot_full
                  AND reuse.enrolled
                  AND reuse.mda_udid <> ''
                  AND reuse.security_info_at IS NOT NULL
                  AND reuse.security_info_at
                      > NOW() - ($5::BIGINT * INTERVAL '1 second')
                  AND reuse.security_info_at
                      < NOW() + ($6::BIGINT * INTERVAL '1 second')
                  AND reuse.hard_untrust_epoch < $7
                  AND NOT EXISTS (
                      SELECT 1
                      FROM rust_coord.provider_hard_untrust_epochs AS untrusted
                      WHERE untrusted.provider_id = $8
                        AND untrusted.hard_untrust_epoch >= $7
                  )
            )
            "#,
        )
        .bind(se_key)
        .bind(provider_uuid(provider_id).to_string())
        .bind(serial)
        .bind(binary_hash)
        .bind(reuse_seconds)
        .bind(skew_seconds)
        .bind(epoch_i64(session_epoch)?)
        .bind(provider_uuid(provider_id))
        .fetch_one(self.database.pool())
        .await?;
        Ok(row)
    }

    async fn lookup_device(&self, serial: &str) -> Result<MdmDevice, ProviderControlError> {
        let url = self.mdm_url("v1/devices")?;
        let response = self
            .client
            .post(url)
            .basic_auth("micromdm", Some(self.mdm.api_key.as_ref()))
            .json(&json!({"serial_number": serial}))
            .send()
            .await?;
        if !response.status().is_success() {
            return Err(ProviderControlError::MdmUnavailable);
        }
        if response
            .content_length()
            .is_some_and(|length| length > MAX_MDM_RESPONSE_BYTES as u64)
        {
            return Err(ProviderControlError::MdmResponseTooLarge);
        }
        let bytes = response.bytes().await?;
        if bytes.len() > MAX_MDM_RESPONSE_BYTES {
            return Err(ProviderControlError::MdmResponseTooLarge);
        }
        let devices: MdmDevices = serde_json::from_slice(&bytes)?;
        devices
            .devices
            .into_iter()
            .find(|device| device.serial_number == serial)
            .ok_or(ProviderControlError::DeviceNotEnrolled)
    }

    #[allow(clippy::too_many_arguments)]
    async fn persist_mdm_expectation(
        &self,
        command_uuid: &str,
        provider_id: ProviderId,
        session_epoch: SessionEpoch,
        serial: &str,
        udid: &str,
        se_public_key: &str,
        binary_hash: &str,
        expected_sip: bool,
        expected_secure_boot: bool,
    ) -> Result<(), ProviderControlError> {
        if !expected_sip || !expected_secure_boot {
            self.hard_untrust(
                provider_id,
                session_epoch,
                se_public_key,
                "signed posture failed",
            )
            .await?;
            return Err(ProviderControlError::PostureMismatch);
        }
        let ttl_seconds = i64::try_from(MDM_COMMAND_TTL.as_secs())
            .map_err(|_| ProviderControlError::InvalidMdmConfiguration)?;
        let owner_epoch = self
            .database
            .authority()
            .ok_or(ProviderControlError::OwnershipUnavailable)?
            .0
            .epoch();
        let mut transaction = self.database.begin_owned().await?;
        sqlx::query(
            r#"
            INSERT INTO rust_coord.mdm_command_expectations (
                command_uuid, command, provider_id, session_epoch, serial, udid,
                se_public_key, binary_hash, expected_sip,
                expected_secure_boot, owner_epoch, expires_at
            )
            VALUES (
                $1, 'SecurityInfo', $2, $3, $4, $5, $6, $7, $8, $9, $10,
                NOW() + ($11::BIGINT * INTERVAL '1 second')
            )
            "#,
        )
        .bind(command_uuid)
        .bind(provider_uuid(provider_id))
        .bind(epoch_i64(session_epoch)?)
        .bind(serial)
        .bind(udid)
        .bind(se_public_key)
        .bind(binary_hash)
        .bind(expected_sip)
        .bind(expected_secure_boot)
        .bind(owner_epoch)
        .bind(ttl_seconds)
        .execute(transaction.connection())
        .await?;
        transaction.commit().await?;
        Ok(())
    }

    async fn send_security_info(
        &self,
        command_uuid: &str,
        udid: &str,
    ) -> Result<(), ProviderControlError> {
        let mut command_url = self.mdm_url("v1/commands/")?;
        command_url
            .path_segments_mut()
            .map_err(|_| ProviderControlError::InvalidMdmConfiguration)?
            .pop_if_empty()
            .push(udid);
        let plist = format!(
            concat!(
                r#"<?xml version="1.0" encoding="UTF-8"?>"#,
                r#"<plist version="1.0"><dict><key>Command</key><dict>"#,
                r#"<key>RequestType</key><string>SecurityInfo</string>"#,
                r#"</dict><key>CommandUUID</key><string>{}</string>"#,
                r#"</dict></plist>"#
            ),
            command_uuid
        );
        let response = self
            .client
            .post(command_url)
            .basic_auth("micromdm", Some(self.mdm.api_key.as_ref()))
            .header(reqwest::header::CONTENT_TYPE, "application/xml")
            .body(plist)
            .send()
            .await?;
        if !response.status().is_success() {
            return Err(ProviderControlError::MdmUnavailable);
        }
        let mut push_url = self.mdm_url("push/")?;
        push_url
            .path_segments_mut()
            .map_err(|_| ProviderControlError::InvalidMdmConfiguration)?
            .pop_if_empty()
            .push(udid);
        let push = self
            .client
            .get(push_url)
            .basic_auth("micromdm", Some(self.mdm.api_key.as_ref()))
            .send()
            .await?;
        if !push.status().is_success() {
            return Err(ProviderControlError::MdmUnavailable);
        }
        Ok(())
    }

    async fn wait_for_mdm_result(&self, command_uuid: &str) -> Result<(), ProviderControlError> {
        let deadline = Instant::now() + self.mdm.security_info_timeout;
        loop {
            let row = sqlx::query_as::<_, MdmExpectationStatus>(
                r#"
                SELECT status
                FROM rust_coord.mdm_command_expectations
                WHERE command_uuid = $1
                "#,
            )
            .bind(command_uuid)
            .fetch_one(self.database.pool())
            .await?;
            match row.status.as_str() {
                "applied" => return Ok(()),
                "rejected" => return Err(ProviderControlError::PostureMismatch),
                "expired" => return Err(ProviderControlError::MdmUnavailable),
                "pending" => {}
                _ => return Err(ProviderControlError::CorruptMdmState),
            }
            if Instant::now() >= deadline {
                self.expire_expectation(command_uuid, "SecurityInfo response timed out")
                    .await?;
                return Err(ProviderControlError::MdmUnavailable);
            }
            sleep(Duration::from_millis(25)).await;
        }
    }

    async fn expire_expectation(
        &self,
        command_uuid: &str,
        reason: &str,
    ) -> Result<(), ProviderControlError> {
        let mut transaction = self.database.begin_owned().await?;
        sqlx::query(
            r#"
            UPDATE rust_coord.mdm_command_expectations
            SET
                status = 'expired',
                failure_reason = $2,
                completed_at = NOW()
            WHERE command_uuid = $1 AND status = 'pending'
            "#,
        )
        .bind(command_uuid)
        .bind(bounded_reason(reason))
        .execute(transaction.connection())
        .await?;
        transaction.commit().await?;
        Ok(())
    }

    async fn apply_mdm_payload(
        &self,
        payload: &Value,
    ) -> Result<ExternalDisposition, ProviderControlError> {
        let evidence = parse_mdm_evidence(payload)?;
        let mut transaction = self.database.begin_owned().await?;
        let expectation = sqlx::query_as::<_, MdmExpectationRow>(
            r#"
            SELECT
                provider_id, session_epoch, serial, udid,
                se_public_key, binary_hash, expected_sip,
                expected_secure_boot, status, expires_at <= NOW() AS expired
            FROM rust_coord.mdm_command_expectations
            WHERE command_uuid = $1 AND command = 'SecurityInfo'
            FOR UPDATE
            "#,
        )
        .bind(&evidence.command_uuid)
        .fetch_optional(transaction.connection())
        .await?
        .ok_or(ProviderControlError::UnsolicitedMdmEvent)?;
        if expectation.status == "applied" {
            transaction.rollback().await?;
            return Ok(ExternalDisposition::Applied);
        }
        if expectation.status == "rejected" {
            transaction.rollback().await?;
            return Ok(ExternalDisposition::Rejected);
        }
        if expectation.expired {
            sqlx::query(
                r#"
                UPDATE rust_coord.mdm_command_expectations
                SET
                    status = 'expired',
                    failure_reason = 'SecurityInfo response arrived after expiry',
                    completed_at = NOW()
                WHERE command_uuid = $1 AND status = 'pending'
                "#,
            )
            .bind(&evidence.command_uuid)
            .execute(transaction.connection())
            .await?;
            transaction.commit().await?;
            return Ok(ExternalDisposition::Rejected);
        }
        let mismatch = evidence.udid != expectation.udid
            || !evidence.sip_enabled
            || evidence.secure_boot_level != "full"
            || evidence.sip_enabled != expectation.expected_sip
            || (evidence.secure_boot_level == "full") != expectation.expected_secure_boot;
        let status = if mismatch { "rejected" } else { "applied" };
        let reason = if mismatch {
            "MDM SecurityInfo contradicted the signed provider posture"
        } else {
            ""
        };
        let evidence_json = serde_json::to_value(&evidence)?;
        sqlx::query(
            r#"
            UPDATE rust_coord.mdm_command_expectations
            SET
                status = $2,
                evidence = $3,
                failure_reason = $4,
                completed_at = NOW()
            WHERE command_uuid = $1 AND status = 'pending'
            "#,
        )
        .bind(&evidence.command_uuid)
        .bind(status)
        .bind(SqlJson(evidence_json))
        .bind(reason)
        .execute(transaction.connection())
        .await?;
        if mismatch {
            let evidence_digest = canonical_json_digest(payload)?;
            let owner_epoch = transaction.context().epoch();
            hard_untrust_in_transaction(
                transaction.connection(),
                expectation.provider_id,
                expectation.session_epoch,
                &expectation.se_public_key,
                reason,
                evidence_digest.as_bytes(),
                owner_epoch,
            )
            .await?;
            transaction.commit().await?;
            return Ok(ExternalDisposition::Rejected);
        }
        sqlx::query(
            r#"
            INSERT INTO public.provider_trust_reuse (
                se_pubkey, provider_id, serial, trust_level, binary_hash,
                sip_enabled, secure_boot_full, mda_udid, verified_at,
                hard_untrust_epoch, enrolled, security_info_at
            )
            VALUES (
                $1, $2, $3, 'hardware', $4, TRUE, TRUE, $5, NOW(),
                GREATEST($6 - 1, 0), TRUE, NOW()
            )
            ON CONFLICT (se_pubkey) DO UPDATE SET
                provider_id = EXCLUDED.provider_id,
                serial = EXCLUDED.serial,
                trust_level = EXCLUDED.trust_level,
                binary_hash = EXCLUDED.binary_hash,
                sip_enabled = EXCLUDED.sip_enabled,
                secure_boot_full = EXCLUDED.secure_boot_full,
                mda_udid = EXCLUDED.mda_udid,
                verified_at = EXCLUDED.verified_at,
                hard_untrust_epoch = EXCLUDED.hard_untrust_epoch,
                enrolled = EXCLUDED.enrolled,
                security_info_at = EXCLUDED.security_info_at
            "#,
        )
        .bind(&expectation.se_public_key)
        .bind(expectation.provider_id.to_string())
        .bind(&expectation.serial)
        .bind(&expectation.binary_hash)
        .bind(&expectation.udid)
        .bind(expectation.session_epoch)
        .execute(transaction.connection())
        .await?;
        let provider_update = sqlx::query(
            r#"
            UPDATE public.providers
            SET
                trust_level = 'hardware',
                attested = TRUE,
                serial_number = $2,
                mdm_udid = $3,
                mdm_enrolled = TRUE,
                mdm_sip_enabled = TRUE,
                mdm_secure_boot_full = TRUE,
                mdm_security_info_at = NOW(),
                last_challenge_verified = NOW()
            WHERE id = $1
              AND se_public_key = $4
              AND hard_untrust_epoch < $5
              AND NOT EXISTS (
                  SELECT 1
                  FROM rust_coord.provider_hard_untrust_epochs AS untrusted
                  WHERE untrusted.provider_id = $6
                    AND untrusted.hard_untrust_epoch >= $5
              )
            "#,
        )
        .bind(expectation.provider_id.to_string())
        .bind(&expectation.serial)
        .bind(&expectation.udid)
        .bind(&expectation.se_public_key)
        .bind(expectation.session_epoch)
        .bind(expectation.provider_id)
        .execute(transaction.connection())
        .await?;
        if provider_update.rows_affected() != 1 {
            return Err(ProviderControlError::HardUntrusted);
        }
        transaction.commit().await?;
        Ok(ExternalDisposition::Applied)
    }

    async fn hard_untrust(
        &self,
        provider_id: ProviderId,
        session_epoch: SessionEpoch,
        se_public_key: &str,
        reason: &str,
    ) -> Result<(), ProviderControlError> {
        let mut transaction = self.database.begin_owned().await?;
        let evidence_digest = canonical_json_digest(&json!({
            "provider_id": provider_uuid(provider_id),
            "session_epoch": session_epoch.0,
            "se_public_key": se_public_key,
            "reason": reason,
        }))?;
        let owner_epoch = transaction.context().epoch();
        hard_untrust_in_transaction(
            transaction.connection(),
            provider_uuid(provider_id),
            epoch_i64(session_epoch)?,
            se_public_key,
            reason,
            evidence_digest.as_bytes(),
            owner_epoch,
        )
        .await?;
        transaction.commit().await?;
        Ok(())
    }

    fn mdm_url(&self, path: &str) -> Result<Url, ProviderControlError> {
        self.mdm
            .base_url
            .join(path)
            .map_err(|_| ProviderControlError::InvalidMdmConfiguration)
    }
}

async fn hard_untrust_in_transaction(
    connection: &mut sqlx::PgConnection,
    provider_id: Uuid,
    session_epoch: i64,
    se_public_key: &str,
    reason: &str,
    evidence_digest: &[u8; 32],
    owner_epoch: i64,
) -> Result<(), ProviderControlError> {
    sqlx::query(
        r#"
        INSERT INTO rust_coord.provider_hard_untrust_epochs (
            provider_id, hard_untrust_epoch, reason, evidence_digest,
            owner_epoch
        )
        VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT (provider_id) DO UPDATE SET
            hard_untrust_epoch = GREATEST(
                provider_hard_untrust_epochs.hard_untrust_epoch,
                EXCLUDED.hard_untrust_epoch
            ),
            reason = CASE
                WHEN EXCLUDED.hard_untrust_epoch
                     >= provider_hard_untrust_epochs.hard_untrust_epoch
                THEN EXCLUDED.reason
                ELSE provider_hard_untrust_epochs.reason
            END,
            evidence_digest = CASE
                WHEN EXCLUDED.hard_untrust_epoch
                     >= provider_hard_untrust_epochs.hard_untrust_epoch
                THEN EXCLUDED.evidence_digest
                ELSE provider_hard_untrust_epochs.evidence_digest
            END,
            owner_epoch = EXCLUDED.owner_epoch,
            version = provider_hard_untrust_epochs.version + 1,
            updated_at = NOW()
        "#,
    )
    .bind(provider_id)
    .bind(session_epoch)
    .bind(bounded_reason(reason))
    .bind(evidence_digest.as_slice())
    .bind(owner_epoch)
    .execute(&mut *connection)
    .await?;
    sqlx::query(
        r#"
        UPDATE public.providers
        SET
            trust_level = 'none',
            connected = FALSE,
            hard_untrust_epoch = GREATEST(hard_untrust_epoch, $2),
            failed_challenges = failed_challenges + 1,
            last_seen = NOW()
        WHERE id = $1
        "#,
    )
    .bind(provider_id.to_string())
    .bind(session_epoch)
    .execute(&mut *connection)
    .await?;
    sqlx::query("DELETE FROM public.provider_trust_reuse WHERE se_pubkey = $1")
        .bind(se_public_key)
        .execute(&mut *connection)
        .await?;
    Ok(())
}

#[derive(Deserialize)]
struct MdmDevices {
    devices: Vec<MdmDevice>,
}

#[derive(Deserialize)]
struct MdmDevice {
    serial_number: String,
    udid: String,
    enrollment_status: bool,
}

#[derive(FromRow)]
struct ProviderTokenAuthRow {
    token_hash: String,
    account_id: String,
    provider_id: String,
    active: bool,
}

#[derive(FromRow)]
struct MdmExpectationStatus {
    status: String,
}

#[derive(FromRow)]
struct MdmProviderFenceRow {
    provider_id: Uuid,
    session_epoch: i64,
}

#[derive(FromRow)]
struct MdmExpectationRow {
    provider_id: Uuid,
    session_epoch: i64,
    serial: String,
    udid: String,
    se_public_key: String,
    binary_hash: String,
    expected_sip: bool,
    expected_secure_boot: bool,
    status: String,
    expired: bool,
}

#[derive(Clone, Debug, serde::Serialize)]
struct MdmSecurityEvidence {
    command_uuid: String,
    udid: String,
    sip_enabled: bool,
    secure_boot_level: String,
    authenticated_root_enabled: Option<bool>,
}

fn parse_mdm_evidence(payload: &Value) -> Result<MdmSecurityEvidence, ProviderControlError> {
    let event = payload
        .get("acknowledge_event")
        .and_then(Value::as_object)
        .ok_or(ProviderControlError::MalformedMdmEvent)?;
    if event.get("status").and_then(Value::as_str) != Some("Acknowledged") {
        return Err(ProviderControlError::MalformedMdmEvent);
    }
    let udid = event
        .get("udid")
        .and_then(Value::as_str)
        .filter(|value| valid_identity_text(value, 256))
        .ok_or(ProviderControlError::MalformedMdmEvent)?;
    let encoded = event
        .get("raw_payload")
        .and_then(Value::as_str)
        .ok_or(ProviderControlError::MalformedMdmEvent)?;
    let raw = STANDARD
        .decode(encoded)
        .map_err(|_| ProviderControlError::MalformedMdmEvent)?;
    if raw.len() > MAX_MDM_RESPONSE_BYTES {
        return Err(ProviderControlError::MdmResponseTooLarge);
    }
    let plist = std::str::from_utf8(&raw).map_err(|_| ProviderControlError::MalformedMdmEvent)?;
    if !plist.contains("<key>SecurityInfo</key>") {
        return Err(ProviderControlError::MalformedMdmEvent);
    }
    let command_uuid = plist_string(plist, "CommandUUID")?;
    if !valid_identity_text(&command_uuid, 128) {
        return Err(ProviderControlError::MalformedMdmEvent);
    }
    let sip_enabled = plist_bool(plist, "SystemIntegrityProtectionEnabled")?;
    let secure_boot_level = plist_string(plist, "SecureBootLevel")?;
    if !matches!(
        secure_boot_level.as_str(),
        "full" | "reduced" | "permissive"
    ) {
        return Err(ProviderControlError::MalformedMdmEvent);
    }
    let authenticated_root_enabled = plist_optional_bool(plist, "AuthenticatedRootVolumeEnabled")?;
    Ok(MdmSecurityEvidence {
        command_uuid,
        udid: udid.to_owned(),
        sip_enabled,
        secure_boot_level,
        authenticated_root_enabled,
    })
}

fn plist_string(plist: &str, key: &str) -> Result<String, ProviderControlError> {
    let marker = format!("<key>{key}</key>");
    let mut matches = plist.match_indices(&marker);
    let (first, _) = matches
        .next()
        .ok_or(ProviderControlError::MalformedMdmEvent)?;
    if matches.next().is_some() {
        return Err(ProviderControlError::MalformedMdmEvent);
    }
    let after = plist[first + marker.len()..].trim_start();
    let after_open = after
        .strip_prefix("<string>")
        .ok_or(ProviderControlError::MalformedMdmEvent)?;
    let close = after_open
        .find("</string>")
        .ok_or(ProviderControlError::MalformedMdmEvent)?;
    let value = after_open[..close].trim();
    if value.is_empty() || value.contains('<') || value.contains('&') {
        return Err(ProviderControlError::MalformedMdmEvent);
    }
    Ok(value.to_owned())
}

fn plist_bool(plist: &str, key: &str) -> Result<bool, ProviderControlError> {
    plist_optional_bool(plist, key)?.ok_or(ProviderControlError::MalformedMdmEvent)
}

fn plist_optional_bool(plist: &str, key: &str) -> Result<Option<bool>, ProviderControlError> {
    let marker = format!("<key>{key}</key>");
    let mut matches = plist.match_indices(&marker);
    let Some((first, _)) = matches.next() else {
        return Ok(None);
    };
    if matches.next().is_some() {
        return Err(ProviderControlError::MalformedMdmEvent);
    }
    let after = plist[first + marker.len()..].trim_start();
    if after.starts_with("<true/>") {
        Ok(Some(true))
    } else if after.starts_with("<false/>") {
        Ok(Some(false))
    } else {
        Err(ProviderControlError::MalformedMdmEvent)
    }
}

fn validate_token(token: &str) -> Result<(), ProviderControlError> {
    if token.is_empty()
        || token.len() > MAX_TOKEN_BYTES
        || token
            .bytes()
            .any(|byte| byte.is_ascii_whitespace() || byte.is_ascii_control())
    {
        return Err(ProviderControlError::InvalidCredential);
    }
    Ok(())
}

fn valid_identity_text(value: &str, maximum: usize) -> bool {
    !value.is_empty()
        && value.len() <= maximum
        && value.trim() == value
        && !value.chars().any(char::is_control)
}

fn hash_secret(value: &str) -> String {
    hex_digest(Sha256::digest(value.as_bytes()).into())
}

fn constant_time_hash_match(expected: &str, stored: &str) -> bool {
    bool::from(expected.as_bytes().ct_eq(stored.as_bytes()))
}

fn normalize_sha256(value: &str) -> Result<String, ProviderControlError> {
    let normalized = value.trim().to_ascii_lowercase();
    if normalized.len() != 64 || normalized.bytes().any(|byte| !byte.is_ascii_hexdigit()) {
        return Err(ProviderControlError::InvalidBinaryHash);
    }
    Ok(normalized)
}

fn hex_digest(digest: [u8; 32]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(64);
    for byte in digest {
        encoded.push(HEX[usize::from(byte >> 4)] as char);
        encoded.push(HEX[usize::from(byte & 0x0f)] as char);
    }
    encoded
}

fn provider_uuid(provider_id: ProviderId) -> Uuid {
    Uuid::from_bytes(*provider_id.as_bytes())
}

fn epoch_i64(epoch: SessionEpoch) -> Result<i64, ProviderControlError> {
    i64::try_from(epoch.0).map_err(|_| ProviderControlError::SessionEpochOverflow)
}

fn session_identifier(provider_id: ProviderId, generation: Uuid, epoch: SessionEpoch) -> String {
    format!("rust:{provider_id}:{generation}:{}", epoch.0)
}

fn bounded_reason(reason: &str) -> &str {
    if reason.len() <= 4_096 {
        reason
    } else {
        "provider control-plane failure"
    }
}

fn disposition_status(disposition: ExternalDisposition) -> &'static str {
    match disposition {
        ExternalDisposition::Applied => "applied",
        ExternalDisposition::Rejected => "rejected",
        ExternalDisposition::Ignored => "ignored",
        ExternalDisposition::Failed => "failed",
    }
}

fn disposition_from_status(status: &str) -> ExternalDisposition {
    match status {
        "applied" => ExternalDisposition::Applied,
        "rejected" => ExternalDisposition::Rejected,
        "failed" => ExternalDisposition::Failed,
        _ => ExternalDisposition::Ignored,
    }
}

#[derive(Debug, Error)]
pub enum ProviderControlError {
    #[error("invalid configured provider credential")]
    InvalidConfiguredCredential,
    #[error("invalid provider credential")]
    InvalidCredential,
    #[error("provider credential attempted to rotate its bound identity")]
    IdentityRotation,
    #[error("stored provider identity is corrupt")]
    CorruptIdentity,
    #[error("provider registration is missing a stable hardware serial")]
    MissingSerial,
    #[error("provider binary hash is not a canonical SHA-256 digest")]
    InvalidBinaryHash,
    #[error("provider session epoch exceeds the durable representation")]
    SessionEpochOverflow,
    #[error("provider epoch is durably hard-untrusted")]
    HardUntrusted,
    #[error("MicroMDM configuration is invalid")]
    InvalidMdmConfiguration,
    #[error("MicroMDM is unavailable")]
    MdmUnavailable,
    #[error("MicroMDM response exceeded its finite bound")]
    MdmResponseTooLarge,
    #[error("provider device is not currently enrolled in MDM")]
    DeviceNotEnrolled,
    #[error("MDM SecurityInfo contradicts the provider's signed posture")]
    PostureMismatch,
    #[error("MDM webhook event is malformed")]
    MalformedMdmEvent,
    #[error("MDM webhook event did not answer an outstanding command")]
    UnsolicitedMdmEvent,
    #[error("MDM CommandUUID was reused with different evidence")]
    MdmEventConflict,
    #[error("durable MDM command state is corrupt")]
    CorruptMdmState,
    #[error("coordinator ownership is unavailable")]
    OwnershipUnavailable,
    #[error("coordinator is draining")]
    Draining,
    #[error("build bounded MicroMDM client: {0}")]
    HttpClient(reqwest::Error),
    #[error("MicroMDM HTTP request failed: {0}")]
    Http(#[from] reqwest::Error),
    #[error("decode MicroMDM payload: {0}")]
    Json(#[from] serde_json::Error),
    #[error("provider control database operation: {0}")]
    Sql(#[from] sqlx::Error),
    #[error(transparent)]
    Database(#[from] DatabaseError),
    #[error(transparent)]
    Ledger(#[from] crate::ledger::LedgerError),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn security_info_parser_rejects_duplicate_or_missing_posture() {
        let plist = concat!(
            "<plist><dict><key>CommandUUID</key><string>command-1</string>",
            "<key>SecurityInfo</key><dict>",
            "<key>SystemIntegrityProtectionEnabled</key><true/>",
            "<key>SecureBootLevel</key><string>full</string>",
            "</dict></dict></plist>"
        );
        let payload = json!({
            "acknowledge_event": {
                "udid": "device-1",
                "status": "Acknowledged",
                "raw_payload": STANDARD.encode(plist),
            }
        });
        let evidence = parse_mdm_evidence(&payload).expect("valid SecurityInfo");
        assert!(evidence.sip_enabled);
        assert_eq!(evidence.secure_boot_level, "full");

        let duplicate = plist.replace(
            "</dict></dict>",
            "<key>SecureBootLevel</key><string>full</string></dict></dict>",
        );
        let payload = json!({
            "acknowledge_event": {
                "udid": "device-1",
                "status": "Acknowledged",
                "raw_payload": STANDARD.encode(duplicate),
            }
        });
        assert!(matches!(
            parse_mdm_evidence(&payload),
            Err(ProviderControlError::MalformedMdmEvent)
        ));
    }
}
