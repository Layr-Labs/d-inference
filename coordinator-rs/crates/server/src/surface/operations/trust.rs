use std::{
    collections::{BTreeMap, BTreeSet, HashMap},
    fmt, fs,
    io::Write as _,
    process::{Command, Stdio},
    sync::{Arc, Mutex},
};

use axum::{
    Json,
    body::{Body, to_bytes},
    extract::{Query, Request, State},
    http::{HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::{Row, types::Json as SqlJson};
use thiserror::Error;
use uuid::Uuid;

use super::{OperationsState, auth::require_public, error::OperationsError, lock};

const MAX_ENROLL_BODY: usize = 64 * 1024;
const MAX_MDM_BODY: usize = 1024 * 1024;

#[derive(Clone)]
pub struct EnrollmentConfig {
    pub topic: Arc<str>,
    pub scep_challenge: Arc<str>,
    certificate_pem: Arc<str>,
    private_key_pem: Arc<str>,
    openssl_path: Arc<str>,
}

impl fmt::Debug for EnrollmentConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("EnrollmentConfig")
            .field("topic", &self.topic)
            .field("scep_challenge", &"<redacted>")
            .field("certificate_pem", &"<redacted>")
            .field("private_key_pem", &"<redacted>")
            .field("openssl_path", &self.openssl_path)
            .finish()
    }
}

impl EnrollmentConfig {
    pub fn cms(
        topic: impl Into<Arc<str>>,
        scep_challenge: impl Into<Arc<str>>,
        certificate_pem: impl Into<Arc<str>>,
        private_key_pem: impl Into<Arc<str>>,
    ) -> Result<Self, EnrollmentConfigError> {
        let config = Self {
            topic: topic.into(),
            scep_challenge: scep_challenge.into(),
            certificate_pem: certificate_pem.into(),
            private_key_pem: private_key_pem.into(),
            openssl_path: Arc::from("openssl"),
        };
        config.validate()?;
        Ok(config)
    }

    #[must_use]
    pub fn with_openssl_path(mut self, path: impl Into<Arc<str>>) -> Self {
        self.openssl_path = path.into();
        self
    }

    pub(super) fn validate(&self) -> Result<(), EnrollmentConfigError> {
        if self.topic.is_empty()
            || self.scep_challenge.is_empty()
            || self.certificate_pem.is_empty()
            || self.private_key_pem.is_empty()
            || self.openssl_path.is_empty()
        {
            return Err(EnrollmentConfigError::MissingMaterial);
        }
        if !self.topic.starts_with("com.apple.mgmt.") || self.topic.chars().any(char::is_control) {
            return Err(EnrollmentConfigError::InvalidTopic);
        }
        cms_sign(self, b"darkbloom enrollment signer validation")
            .map(|_| ())
            .map_err(EnrollmentConfigError::Signer)
    }
}

#[derive(Debug, Error)]
pub enum EnrollmentConfigError {
    #[error("enrollment requires topic, challenge, CMS certificate, and CMS private key")]
    MissingMaterial,
    #[error("enrollment topic is not a valid Apple MDM topic")]
    InvalidTopic,
    #[error("enrollment CMS signer validation failed: {0}")]
    Signer(Arc<str>),
}

#[derive(Clone, Debug)]
pub(super) struct MdmCommandExpectation {
    pub command_uuid: Arc<str>,
    pub command: Arc<str>,
}

#[derive(Debug, Default)]
pub(super) struct MdmCommandRegistry {
    commands: Mutex<BTreeMap<Arc<str>, Arc<str>>>,
}

impl MdmCommandRegistry {
    pub(super) fn insert(&self, expectation: MdmCommandExpectation) -> Result<(), Arc<str>> {
        if !valid_command_id(&expectation.command_uuid) || !valid_command(&expectation.command) {
            return Err(Arc::from("command UUID or command is invalid"));
        }
        let mut commands = lock(&self.commands);
        if let Some(existing) = commands.get(&expectation.command_uuid)
            && existing != &expectation.command
        {
            return Err(Arc::from("command UUID already expects another command"));
        }
        commands.insert(expectation.command_uuid, expectation.command);
        Ok(())
    }

    fn expects(&self, command_uuid: &str, command: &str) -> bool {
        lock(&self.commands)
            .get(command_uuid)
            .is_some_and(|expected| expected.as_ref() == command)
    }

    fn consume(&self, command_uuid: &str, command: &str) {
        let mut commands = lock(&self.commands);
        if commands
            .get(command_uuid)
            .is_some_and(|expected| expected.as_ref() == command)
        {
            commands.remove(command_uuid);
        }
    }
}

pub(super) async fn provider_attestation(
    State(state): State<Arc<OperationsState>>,
    headers: axum::http::HeaderMap,
) -> Result<Json<Value>, OperationsError> {
    require_public(&state.auth, &headers)?;
    let Some(pilot) = state.pilot() else {
        return Ok(Json(attestation_response(Vec::new())));
    };
    let fleet = pilot.fleet_snapshot();
    let current = fleet
        .providers()
        .map(|provider| {
            (
                provider.provider().fence().provider_id.to_string(),
                provider,
            )
        })
        .collect::<BTreeMap<_, _>>();
    if current.is_empty() {
        return Ok(Json(attestation_response(Vec::new())));
    }
    let ids = current.keys().cloned().collect::<Vec<_>>();
    let rows = sqlx::query(
        r#"
        SELECT id, hardware, models, trust_level, attested, attestation_result,
               se_public_key, serial_number, mda_verified, mda_cert_chain,
               runtime_verified, version,
               to_char(last_challenge_verified AT TIME ZONE 'UTC',
                       'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS last_challenge_verified,
               failed_challenges
        FROM public.providers WHERE id = ANY($1) ORDER BY id
        "#,
    )
    .bind(&ids)
    .fetch_all(state.pool())
    .await
    .map_err(|error| OperationsError::internal("load provider attestation evidence", error))?;
    let mut seen = BTreeSet::new();
    let mut providers = Vec::with_capacity(current.len());
    for row in rows {
        let id = row.get::<String, _>("id");
        let Some(runtime) = current.get(&id) else {
            continue;
        };
        seen.insert(id.clone());
        let trust_level = row.get::<String, _>("trust_level");
        let hardware_trust = trust_level == "hardware";
        let evidence = row
            .get::<Option<SqlJson<Value>>, _>("attestation_result")
            .map(|value| value.0)
            .unwrap_or(Value::Null);
        let cert_chain = if hardware_trust {
            row.get::<Option<SqlJson<Value>>, _>("mda_cert_chain")
                .map(|value| value.0)
                .unwrap_or_else(|| json!([]))
        } else {
            json!([])
        };
        providers.push(json!({
            "provider_id": id,
            "model_id": runtime.provider().fence().model_id.to_string(),
            "hardware_class": runtime.provider().hardware().to_string(),
            "health": runtime.provider().health(),
            "trust_revision": runtime.provider().fence().trust_revision.get(),
            "hardware": row.get::<SqlJson<Value>, _>("hardware").0,
            "models": row.get::<SqlJson<Value>, _>("models").0,
            "trust_level": trust_level,
            "attested": row.get::<bool, _>("attested"),
            "mdm_verified": hardware_trust,
            "mda_verified": hardware_trust && row.get::<bool, _>("mda_verified"),
            "mda_cert_chain_b64": cert_chain,
            "runtime_verified": row.get::<bool, _>("runtime_verified"),
            "version": row.get::<String, _>("version"),
            "serial_number": row.get::<String, _>("serial_number"),
            "se_public_key": row.get::<String, _>("se_public_key"),
            "failed_challenges": row.get::<i32, _>("failed_challenges"),
            "last_challenge_verified": row
                .get::<Option<String>, _>("last_challenge_verified"),
            "raw_evidence": evidence,
            "acme_verified": false,
        }));
    }
    for (id, runtime) in current {
        if seen.contains(&id) {
            continue;
        }
        providers.push(json!({
            "provider_id": id,
            "model_id": runtime.provider().fence().model_id.to_string(),
            "hardware_class": runtime.provider().hardware().to_string(),
            "health": runtime.provider().health(),
            "trust_revision": runtime.provider().fence().trust_revision.get(),
            "trust_level": "unknown",
            "attested": false,
            "mdm_verified": false,
            "mda_verified": false,
            "mda_cert_chain_b64": [],
            "raw_evidence": null,
            "acme_verified": false,
        }));
    }
    Ok(Json(attestation_response(providers)))
}

pub(super) async fn runtime_manifest(
    State(state): State<Arc<OperationsState>>,
    headers: axum::http::HeaderMap,
) -> Result<Json<Value>, OperationsError> {
    require_public(&state.auth, &headers)?;
    let Some(manifest) = &state.settings.runtime_manifest else {
        return Ok(Json(json!({"configured": false})));
    };
    let mut response = manifest
        .as_object()
        .expect("operations builder validates runtime manifest")
        .clone();
    response.insert("configured".to_owned(), Value::Bool(true));
    Ok(Json(Value::Object(response)))
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct EnrollRequest {
    serial_number: String,
}

pub(super) async fn enroll(
    State(state): State<Arc<OperationsState>>,
    request: Request,
) -> Result<Response, OperationsError> {
    let config = state
        .settings
        .enrollment
        .as_ref()
        .ok_or_else(|| OperationsError::unavailable("enrollment is not configured"))?
        .clone();
    let body = to_bytes(request.into_body(), MAX_ENROLL_BODY)
        .await
        .map_err(|_| OperationsError::payload_too_large("enrollment body exceeds 64KB"))?;
    let input: EnrollRequest = serde_json::from_slice(&body)
        .map_err(|error| OperationsError::bad_request(format!("invalid JSON: {error}")))?;
    if !valid_serial(&input.serial_number) {
        return Err(OperationsError::bad_request("invalid serial number format"));
    }
    let profile = enrollment_profile(
        &input.serial_number,
        state
            .settings
            .public_base_url
            .as_str()
            .trim_end_matches('/'),
        &config,
    );
    let signed = tokio::task::spawn_blocking(move || cms_sign(&config, profile.as_bytes()))
        .await
        .map_err(|error| OperationsError::internal("join enrollment signer", error))?
        .map_err(|error| OperationsError::internal("sign enrollment profile", error))?;
    let mut response = Body::from(signed).into_response();
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/x-apple-aspen-config"),
    );
    if let Ok(value) = HeaderValue::from_str(&format!(
        "attachment; filename=\"Darkbloom-Enroll-{}.mobileconfig\"",
        input.serial_number
    )) {
        response
            .headers_mut()
            .insert(header::CONTENT_DISPOSITION, value);
    }
    state.metrics.increment("enrollment_profiles_signed");
    Ok(response)
}

pub(super) async fn mdm_webhook(
    State(state): State<Arc<OperationsState>>,
    Query(query): Query<HashMap<String, String>>,
    request: Request,
) -> Result<StatusCode, OperationsError> {
    let query_token = query
        .get(state.auth.mdm.query_parameter.as_ref())
        .map(String::as_str);
    if !state.auth.mdm.accepts(request.headers(), query_token) {
        return Err(OperationsError::forbidden("invalid MDM webhook secret"));
    }
    let body = to_bytes(request.into_body(), MAX_MDM_BODY)
        .await
        .map_err(|_| OperationsError::payload_too_large("MDM webhook body exceeds 1MiB"))?;
    let payload: Value = serde_json::from_slice(&body)
        .map_err(|error| OperationsError::bad_request(format!("invalid MDM JSON: {error}")))?;
    let (command_uuid, command) = mdm_command(&payload)?;
    let digest: [u8; 32] = Sha256::digest(&body).into();
    if !state.mdm_commands.expects(&command_uuid, &command) {
        let existing = sqlx::query(
            r#"
            SELECT event_kind, payload_digest
            FROM rust_coord.external_events
            WHERE source='micromdm' AND event_id=$1
            "#,
        )
        .bind(&command_uuid)
        .fetch_optional(state.pool())
        .await
        .map_err(|error| OperationsError::internal("load prior MDM event", error))?;
        if let Some(existing) = existing {
            let prior_command = existing.get::<String, _>("event_kind");
            let prior_digest = existing.get::<Vec<u8>, _>("payload_digest");
            if prior_command == command && prior_digest.as_slice() == digest {
                return Ok(StatusCode::OK);
            }
            return Err(OperationsError::conflict(
                "mdm_event_conflict",
                "CommandUUID was already used with different evidence",
            ));
        }
        return Err(OperationsError::forbidden(
            "unsolicited or mismatched MDM command response",
        ));
    }
    let event_id = Uuid::new_v4();
    let mut transaction = state
        .database
        .begin_owned()
        .await
        .map_err(|error| OperationsError::internal("begin MDM event", error))?;
    let inserted = sqlx::query(
        r#"
        INSERT INTO rust_coord.external_events (
            external_event_id, source, event_id, event_kind, payload_digest,
            payload, status, owner_epoch
        ) VALUES ($1,'micromdm',$2,$3,$4,$5,'pending',$6)
        ON CONFLICT (source, event_id) DO NOTHING
        "#,
    )
    .bind(event_id)
    .bind(&command_uuid)
    .bind(&command)
    .bind(digest.as_slice())
    .bind(SqlJson(payload))
    .bind(state.settings.owner_epoch)
    .execute(transaction.connection())
    .await
    .map_err(|error| OperationsError::internal("persist MDM event", error))?;
    if inserted.rows_affected() == 0 {
        let existing: Vec<u8> = sqlx::query_scalar(
            "SELECT payload_digest FROM rust_coord.external_events WHERE source='micromdm' AND event_id=$1",
        )
        .bind(&command_uuid)
        .fetch_one(transaction.connection())
        .await
        .map_err(|error| OperationsError::internal("load duplicate MDM event", error))?;
        if existing.as_slice() != digest {
            return Err(OperationsError::conflict(
                "mdm_event_conflict",
                "CommandUUID was already used with different evidence",
            ));
        }
    }
    transaction
        .commit()
        .await
        .map_err(|error| OperationsError::internal("commit MDM event", error))?;
    state.mdm_commands.consume(&command_uuid, &command);
    state.mark_mutation();
    state.metrics.increment("mdm_webhooks_accepted");
    Ok(StatusCode::OK)
}

fn attestation_response(providers: Vec<Value>) -> Value {
    json!({
        "providers": providers,
        "apple_root_ca_url": "https://www.apple.com/certificateauthority/",
        "apple_enterprise_root_ca": "Apple Enterprise Attestation Root CA",
        "verification_instructions":
            "Verify mda_cert_chain_b64 against Apple's Enterprise Attestation Root CA and inspect raw_evidence.",
    })
}

fn enrollment_profile(serial: &str, base_url: &str, config: &EnrollmentConfig) -> String {
    let profile_uuid = Uuid::new_v4();
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>PayloadContent</key><array>
<dict><key>PayloadContent</key><dict>
<key>Challenge</key><string>{challenge}</string>
<key>Key Type</key><string>RSA</string><key>Key Usage</key><integer>5</integer>
<key>Keysize</key><integer>2048</integer>
<key>Name</key><string>Device Management Identity Certificate</string>
<key>Subject</key><array><array><array><string>O</string><string>Darkbloom</string></array></array></array>
<key>URL</key><string>{base_url}/scep</string></dict>
<key>PayloadDisplayName</key><string>SCEP</string>
<key>PayloadIdentifier</key><string>io.darkbloom.enroll.scep</string>
<key>PayloadType</key><string>com.apple.security.scep</string>
<key>PayloadUUID</key><string>D01D95F9-762E-4538-A9B3-4D949D55577C</string>
<key>PayloadVersion</key><integer>1</integer></dict>
<dict><key>AccessRights</key><integer>1041</integer>
<key>CheckInURL</key><string>{base_url}/mdm/checkin</string>
<key>CheckOutWhenRemoved</key><true/>
<key>IdentityCertificateUUID</key><string>D01D95F9-762E-4538-A9B3-4D949D55577C</string>
<key>PayloadIdentifier</key><string>io.darkbloom.enroll.mdm</string>
<key>PayloadType</key><string>com.apple.mdm</string>
<key>PayloadUUID</key><string>4DF05DBF-6D20-41A4-8072-A51D327258E7</string>
<key>PayloadVersion</key><integer>1</integer>
<key>ServerURL</key><string>{base_url}/mdm/connect</string>
<key>SignMessage</key><true/><key>Topic</key><string>{topic}</string></dict>
</array>
<key>PayloadDescription</key><string>Darkbloom provider read-only security enrollment.</string>
<key>PayloadDisplayName</key><string>Darkbloom Provider Enrollment</string>
<key>PayloadIdentifier</key><string>io.darkbloom.enroll.{serial}</string>
<key>PayloadOrganization</key><string>Darkbloom</string>
<key>PayloadType</key><string>Configuration</string>
<key>PayloadUUID</key><string>{profile_uuid}</string>
<key>PayloadVersion</key><integer>1</integer>
</dict></plist>"#,
        challenge = xml_escape(&config.scep_challenge),
        topic = xml_escape(&config.topic),
    )
}

fn cms_sign(config: &EnrollmentConfig, input: &[u8]) -> Result<Vec<u8>, Arc<str>> {
    let directory = std::env::temp_dir().join(format!("darkbloom-enroll-{}", Uuid::new_v4()));
    fs::create_dir(&directory).map_err(|error| Arc::from(error.to_string()))?;
    let certificate = directory.join("signer.pem");
    let private_key = directory.join("signer.key");
    let result = (|| {
        write_secret(&certificate, config.certificate_pem.as_bytes())?;
        write_secret(&private_key, config.private_key_pem.as_bytes())?;
        let mut child = Command::new(config.openssl_path.as_ref())
            .args([
                "cms",
                "-sign",
                "-binary",
                "-outform",
                "DER",
                "-nosmimecap",
                "-nodetach",
                "-signer",
            ])
            .arg(&certificate)
            .arg("-inkey")
            .arg(&private_key)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|error| Arc::from(error.to_string()))?;
        child
            .stdin
            .take()
            .ok_or_else(|| Arc::from("CMS signer stdin unavailable"))?
            .write_all(input)
            .map_err(|error| Arc::from(error.to_string()))?;
        let output = child
            .wait_with_output()
            .map_err(|error| Arc::from(error.to_string()))?;
        if !output.status.success() || output.stdout.is_empty() {
            return Err(Arc::from(format!("openssl cms exited {}", output.status)));
        }
        Ok(output.stdout)
    })();
    let _ = fs::remove_dir_all(directory);
    result
}

fn write_secret(path: &std::path::Path, contents: &[u8]) -> Result<(), Arc<str>> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        let mut file = fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(path)
            .map_err(|error| Arc::from(error.to_string()))?;
        file.write_all(contents)
            .map_err(|error| Arc::from(error.to_string()))
    }
    #[cfg(not(unix))]
    {
        fs::write(path, contents).map_err(|error| Arc::from(error.to_string()))
    }
}

fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

fn valid_serial(serial: &str) -> bool {
    (8..=14).contains(&serial.len())
        && serial
            .bytes()
            .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit())
}

fn valid_command_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
}

fn valid_command(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value.chars().all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-')
        })
}

fn mdm_command(payload: &Value) -> Result<(String, String), OperationsError> {
    let object = payload
        .as_object()
        .ok_or_else(|| OperationsError::bad_request("MDM webhook must be a JSON object"))?;
    if let Some(command_uuid) = string_field(object, &["CommandUUID", "command_uuid"]) {
        let command = string_field(object, &["Command", "command"])
            .or_else(|| {
                object
                    .get("Command")
                    .or_else(|| object.get("command"))
                    .and_then(Value::as_object)
                    .and_then(|value| string_field(value, &["RequestType", "request_type"]))
            })
            .ok_or_else(|| OperationsError::bad_request("MDM command is required"))?;
        return Ok((command_uuid.to_owned(), command.to_owned()));
    }

    let encoded = object
        .get("acknowledge_event")
        .and_then(Value::as_object)
        .and_then(|event| string_field(event, &["raw_payload"]))
        .ok_or_else(|| OperationsError::bad_request("MDM CommandUUID is required"))?;
    let plist = STANDARD
        .decode(encoded)
        .map_err(|_| OperationsError::bad_request("MDM raw_payload is not valid base64"))?;
    let plist = std::str::from_utf8(&plist)
        .map_err(|_| OperationsError::bad_request("MDM raw_payload is not UTF-8 plist XML"))?;
    let command_uuid = plist_string(plist, "CommandUUID")
        .ok_or_else(|| OperationsError::bad_request("MDM CommandUUID is required"))?;
    let command = plist_string(plist, "RequestType")
        .or_else(|| {
            plist
                .contains("<key>SecurityInfo</key>")
                .then(|| "SecurityInfo".to_owned())
        })
        .or_else(|| {
            plist
                .contains("<key>DevicePropertiesAttestation</key>")
                .then(|| "DeviceInformation".to_owned())
        })
        .ok_or_else(|| OperationsError::bad_request("MDM command is required"))?;
    Ok((command_uuid, command))
}

fn plist_string(plist: &str, key: &str) -> Option<String> {
    let marker = format!("<key>{key}</key>");
    let after_key = plist.split_once(&marker)?.1;
    let after_open = after_key.split_once("<string>")?.1;
    let value = after_open.split_once("</string>")?.0.trim();
    (!value.is_empty()).then(|| value.to_owned())
}

fn string_field<'a>(object: &'a serde_json::Map<String, Value>, names: &[&str]) -> Option<&'a str> {
    names
        .iter()
        .find_map(|name| object.get(*name).and_then(Value::as_str))
        .filter(|value| !value.is_empty())
}
