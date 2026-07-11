use std::{
    fmt,
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use futures_util::StreamExt as _;
use reqwest::{Client, Method, StatusCode, Url};
use serde_json::Value;
use sha2::{Digest as _, Sha256};
use subtle::ConstantTimeEq;

use super::error::BillingError;

const MAX_STRIPE_RESPONSE_BYTES: usize = 1024 * 1024;
pub(super) const WEBHOOK_TOLERANCE: Duration = Duration::from_secs(5 * 60);

#[derive(Clone, Debug)]
pub struct StripeSettings {
    pub secret_key: Arc<str>,
    pub webhook_secret: Arc<str>,
    pub connect_webhook_secret: Arc<str>,
    pub api_base: Arc<str>,
    pub checkout_success_url: Arc<str>,
    pub checkout_cancel_url: Arc<str>,
    pub connect_return_url: Arc<str>,
    pub connect_refresh_url: Arc<str>,
    pub platform_country: Arc<str>,
    pub request_timeout: Duration,
}

impl StripeSettings {
    #[must_use]
    pub fn production(
        secret_key: impl Into<Arc<str>>,
        webhook_secret: impl Into<Arc<str>>,
        connect_webhook_secret: impl Into<Arc<str>>,
    ) -> Self {
        Self {
            secret_key: secret_key.into(),
            webhook_secret: webhook_secret.into(),
            connect_webhook_secret: connect_webhook_secret.into(),
            api_base: Arc::from("https://api.stripe.com"),
            checkout_success_url: Arc::from(""),
            checkout_cancel_url: Arc::from(""),
            connect_return_url: Arc::from(""),
            connect_refresh_url: Arc::from(""),
            platform_country: Arc::from("US"),
            request_timeout: Duration::from_secs(30),
        }
    }
}

#[derive(Clone)]
pub(super) struct StripeClient {
    client: Client,
    settings: StripeSettings,
    base: Url,
}

impl fmt::Debug for StripeClient {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("StripeClient")
            .field("base", &self.base)
            .field("platform_country", &self.settings.platform_country)
            .finish_non_exhaustive()
    }
}

impl StripeClient {
    pub(super) fn new(settings: StripeSettings) -> Result<Self, BillingError> {
        if settings.secret_key.is_empty()
            || settings.webhook_secret.is_empty()
            || settings.connect_webhook_secret.is_empty()
        {
            return Err(BillingError::bad_request(
                "Stripe API and both webhook secrets are required",
            ));
        }
        let base = Url::parse(&settings.api_base)
            .map_err(|_| BillingError::bad_request("Stripe API base URL is invalid"))?;
        if !matches!(base.scheme(), "http" | "https") || base.cannot_be_a_base() {
            return Err(BillingError::bad_request(
                "Stripe API base URL must use HTTP or HTTPS",
            ));
        }
        let client = Client::builder()
            .timeout(settings.request_timeout)
            .build()
            .map_err(|error| BillingError::internal("build Stripe HTTP client", error))?;
        Ok(Self {
            client,
            settings,
            base,
        })
    }

    pub(super) fn settings(&self) -> &StripeSettings {
        &self.settings
    }

    pub(super) fn verify_checkout(
        &self,
        body: &[u8],
        signature: &str,
    ) -> Result<Value, BillingError> {
        verify_signature(
            body,
            signature,
            &self.settings.webhook_secret,
            SystemTime::now(),
            WEBHOOK_TOLERANCE,
        )
    }

    pub(super) fn verify_connect(
        &self,
        body: &[u8],
        signature: &str,
    ) -> Result<Value, BillingError> {
        verify_signature(
            body,
            signature,
            &self.settings.connect_webhook_secret,
            SystemTime::now(),
            WEBHOOK_TOLERANCE,
        )
    }

    pub(super) async fn create_checkout(
        &self,
        amount_cents: i64,
        email: &str,
        session_id: &str,
        account_id: &str,
        referral_code: &str,
        idempotency_key: &str,
    ) -> Result<CheckoutSession, StripeError> {
        let success_url = append_checkout_placeholder(&self.settings.checkout_success_url);
        let mut form = vec![
            pair("mode", "payment"),
            pair("success_url", success_url),
            pair("cancel_url", self.settings.checkout_cancel_url.as_ref()),
            pair("line_items[0][price_data][currency]", "usd"),
            pair(
                "line_items[0][price_data][product_data][name]",
                "Darkbloom Inference Credits",
            ),
            pair(
                "line_items[0][price_data][unit_amount]",
                amount_cents.to_string(),
            ),
            pair("line_items[0][quantity]", "1"),
            pair("payment_method_types[0]", "card"),
        ];
        if !email.is_empty() {
            form.push(pair("customer_email", email));
        }
        for (key, value) in [
            ("app", "darkbloom"),
            ("platform", "eigeninference"),
            ("purchase_type", "inference_credits"),
            ("source", "rust_coordinator"),
            ("billing_session_id", session_id),
            ("consumer_key", account_id),
            ("referral_code", referral_code),
        ] {
            form.push(pair(format!("metadata[{key}]"), value));
            form.push(pair(format!("payment_intent_data[metadata][{key}]"), value));
        }
        let value = self
            .request(
                Method::POST,
                "/v1/checkout/sessions",
                Some(form),
                Some(idempotency_key),
                None,
            )
            .await?;
        Ok(CheckoutSession {
            id: string_field(&value, "id")?,
            url: string_field(&value, "url")?,
        })
    }

    pub(super) async fn create_account(
        &self,
        email: &str,
        country: &str,
        idempotency_key: &str,
    ) -> Result<StripeAccount, StripeError> {
        let agreement = required_service_agreement(&self.settings.platform_country, country);
        let mut form = vec![
            pair("type", "express"),
            pair("country", country),
            pair("capabilities[transfers][requested]", "true"),
            pair("business_type", "individual"),
        ];
        if agreement == "recipient" {
            form.push(pair("tos_acceptance[service_agreement]", "recipient"));
        } else {
            form.push(pair("capabilities[card_payments][requested]", "true"));
        }
        if !email.is_empty() {
            form.push(pair("email", email));
            form.push(pair("individual[email]", email));
        }
        add_payout_schedule(&mut form, country);
        let value = self
            .request(
                Method::POST,
                "/v1/accounts",
                Some(form),
                Some(idempotency_key),
                None,
            )
            .await?;
        StripeAccount::parse(&value)
    }

    pub(super) async fn account_link(
        &self,
        account_id: &str,
        return_url: &str,
        refresh_url: &str,
        idempotency_key: &str,
    ) -> Result<String, StripeError> {
        validate_stripe_id(account_id, "acct_")?;
        let value = self
            .request(
                Method::POST,
                "/v1/account_links",
                Some(vec![
                    pair("account", account_id),
                    pair("type", "account_onboarding"),
                    pair("return_url", return_url),
                    pair("refresh_url", refresh_url),
                    pair("collect", "eventually_due"),
                ]),
                Some(idempotency_key),
                None,
            )
            .await?;
        string_field(&value, "url")
    }

    pub(super) async fn account(&self, account_id: &str) -> Result<StripeAccount, StripeError> {
        validate_stripe_id(account_id, "acct_")?;
        let value = self
            .request(
                Method::GET,
                &format!("/v1/accounts/{account_id}"),
                None,
                None,
                None,
            )
            .await?;
        StripeAccount::parse(&value)
    }

    pub(super) async fn ensure_automatic_schedule(
        &self,
        account_id: &str,
        country: &str,
    ) -> Result<(), StripeError> {
        validate_stripe_id(account_id, "acct_")?;
        let mut form = Vec::new();
        add_payout_schedule(&mut form, country);
        self.request(
            Method::POST,
            &format!("/v1/accounts/{account_id}"),
            Some(form),
            Some(&format!("schedule-auto-{account_id}")),
            None,
        )
        .await?;
        Ok(())
    }

    pub(super) async fn create_transfer(
        &self,
        account_id: &str,
        amount_cents: i64,
        idempotency_key: &str,
    ) -> Result<Transfer, StripeError> {
        validate_stripe_id(account_id, "acct_")?;
        let value = self
            .request(
                Method::POST,
                "/v1/transfers",
                Some(vec![
                    pair("amount", amount_cents.to_string()),
                    pair("currency", "usd"),
                    pair("destination", account_id),
                    pair("description", "Darkbloom credit withdrawal"),
                ]),
                Some(idempotency_key),
                None,
            )
            .await?;
        Ok(Transfer {
            id: string_field(&value, "id")?,
        })
    }

    pub(super) async fn create_payout(
        &self,
        account_id: &str,
        amount_cents: i64,
        idempotency_key: &str,
    ) -> Result<Payout, StripeError> {
        validate_stripe_id(account_id, "acct_")?;
        let value = self
            .request(
                Method::POST,
                "/v1/payouts",
                Some(vec![
                    pair("amount", amount_cents.to_string()),
                    pair("currency", "usd"),
                    pair("method", "instant"),
                    pair("description", "Darkbloom credit withdrawal"),
                ]),
                Some(idempotency_key),
                Some(account_id),
            )
            .await?;
        Ok(Payout {
            id: string_field(&value, "id")?,
            status: optional_string(&value, "status"),
            arrival_date: value.get("arrival_date").and_then(Value::as_i64),
        })
    }

    pub(super) async fn payout(
        &self,
        account_id: &str,
        payout_id: &str,
    ) -> Result<Payout, StripeError> {
        validate_stripe_id(account_id, "acct_")?;
        validate_stripe_id(payout_id, "po_")?;
        let value = self
            .request(
                Method::GET,
                &format!("/v1/payouts/{payout_id}"),
                None,
                None,
                Some(account_id),
            )
            .await?;
        Ok(Payout {
            id: string_field(&value, "id")?,
            status: optional_string(&value, "status"),
            arrival_date: value.get("arrival_date").and_then(Value::as_i64),
        })
    }

    async fn request(
        &self,
        method: Method,
        path: &str,
        form: Option<Vec<(String, String)>>,
        idempotency_key: Option<&str>,
        stripe_account: Option<&str>,
    ) -> Result<Value, StripeError> {
        let url = self
            .base
            .join(path.trim_start_matches('/'))
            .map_err(|error| StripeError::definitive(format!("invalid Stripe URL: {error}")))?;
        let mut request = self
            .client
            .request(method, url)
            .bearer_auth(self.settings.secret_key.as_ref());
        if let Some(form) = form {
            let encoded: String = url::form_urlencoded::Serializer::new(String::new())
                .extend_pairs(form)
                .finish();
            request = request
                .header("Content-Type", "application/x-www-form-urlencoded")
                .body(encoded);
        }
        if let Some(key) = idempotency_key {
            request = request.header("Idempotency-Key", key);
        }
        if let Some(account) = stripe_account {
            request = request.header("Stripe-Account", account);
        }
        let response = request
            .send()
            .await
            .map_err(|error| StripeError::unknown(format!("Stripe transport failed: {error}")))?;
        let status = response.status();
        let mut stream = response.bytes_stream();
        let mut body = Vec::new();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|error| {
                StripeError::unknown(format!("Stripe body read failed: {error}"))
            })?;
            if body.len().saturating_add(chunk.len()) > MAX_STRIPE_RESPONSE_BYTES {
                return Err(StripeError::unknown(
                    "Stripe response exceeded the 1 MiB limit",
                ));
            }
            body.extend_from_slice(&chunk);
        }
        if !status.is_success() {
            let error = stripe_error_message(&body);
            return Err(if is_definitive_status(status, &error.0) {
                StripeError::definitive_with_code(error.0, error.1)
            } else {
                StripeError::unknown(error.1)
            });
        }
        serde_json::from_slice(&body)
            .map_err(|error| StripeError::unknown(format!("Stripe returned invalid JSON: {error}")))
    }
}

#[derive(Clone, Debug)]
pub(super) struct CheckoutSession {
    pub id: String,
    pub url: String,
}

#[derive(Clone, Debug)]
pub(super) struct Transfer {
    pub id: String,
}

#[derive(Clone, Debug)]
pub(super) struct Payout {
    pub id: String,
    pub status: String,
    pub arrival_date: Option<i64>,
}

#[derive(Clone, Debug)]
pub(super) struct StripeAccount {
    pub id: String,
    pub country: String,
    pub service_agreement: String,
    pub payout_interval: String,
    pub payouts_enabled: bool,
    pub details_submitted: bool,
    pub disabled_reason: String,
    pub currently_due: Vec<String>,
    pub destination_type: String,
    pub destination_last4: String,
    pub instant_eligible: bool,
}

impl StripeAccount {
    pub(super) fn parse(value: &Value) -> Result<Self, StripeError> {
        let external_accounts = value
            .pointer("/external_accounts/data")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let selected = external_accounts
            .iter()
            .find(|account| {
                account.get("default_for_currency").and_then(Value::as_bool) == Some(true)
            })
            .or_else(|| external_accounts.first());
        let (destination_type, destination_last4, instant_eligible) = selected.map_or_else(
            || (String::new(), String::new(), false),
            |account| {
                let kind = optional_string(account, "object");
                let kind = match kind.as_str() {
                    "bank_account" => "bank".to_owned(),
                    "card" => "card".to_owned(),
                    _ => String::new(),
                };
                let instant = kind == "card"
                    && account.get("funding").and_then(Value::as_str) == Some("debit");
                (kind, optional_string(account, "last4"), instant)
            },
        );
        Ok(Self {
            id: string_field(value, "id")?,
            country: optional_string(value, "country").to_ascii_uppercase(),
            service_agreement: value
                .pointer("/tos_acceptance/service_agreement")
                .and_then(Value::as_str)
                .unwrap_or("full")
                .to_owned(),
            payout_interval: value
                .pointer("/settings/payouts/schedule/interval")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
            payouts_enabled: value
                .get("payouts_enabled")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            details_submitted: value
                .get("details_submitted")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            disabled_reason: value
                .pointer("/requirements/disabled_reason")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
            currently_due: value
                .pointer("/requirements/currently_due")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect(),
            destination_type,
            destination_last4,
            instant_eligible,
        })
    }

    pub(super) fn status(&self) -> &'static str {
        if self.disabled_reason.starts_with("rejected") {
            "rejected"
        } else if self.payouts_enabled {
            "ready"
        } else if self.details_submitted && !self.currently_due.is_empty() {
            "restricted"
        } else {
            "pending"
        }
    }
}

#[derive(Clone, Debug)]
pub(super) struct StripeError {
    pub code: String,
    pub message: String,
    pub outcome: StripeOutcome,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum StripeOutcome {
    Definitive,
    Unknown,
}

impl StripeError {
    fn definitive(message: impl Into<String>) -> Self {
        Self::definitive_with_code(String::new(), message)
    }

    fn definitive_with_code(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            outcome: StripeOutcome::Definitive,
        }
    }

    fn unknown(message: impl Into<String>) -> Self {
        Self {
            code: String::new(),
            message: message.into(),
            outcome: StripeOutcome::Unknown,
        }
    }

    pub(super) fn account_gone(&self) -> bool {
        self.code == "account_invalid"
            || self.message.contains("No such destination")
            || self.message.contains("No such account")
            || self.message.contains("does not have access to account")
    }
}

impl fmt::Display for StripeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.code.is_empty() {
            formatter.write_str(&self.message)
        } else {
            write!(formatter, "[{}] {}", self.code, self.message)
        }
    }
}

impl std::error::Error for StripeError {}

fn is_definitive_status(status: StatusCode, code: &str) -> bool {
    status.is_client_error() && status != StatusCode::CONFLICT && code != "idempotency_key_in_use"
}

fn stripe_error_message(body: &[u8]) -> (String, String) {
    let parsed: Value = serde_json::from_slice(body).unwrap_or(Value::Null);
    let code = parsed
        .pointer("/error/code")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let message = parsed
        .pointer("/error/message")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| String::from_utf8_lossy(body).into_owned());
    (code, message)
}

fn string_field(value: &Value, field: &'static str) -> Result<String, StripeError> {
    value
        .get(field)
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| StripeError::unknown(format!("Stripe response omitted {field}")))
}

fn optional_string(value: &Value, field: &str) -> String {
    value
        .get(field)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned()
}

fn validate_stripe_id(value: &str, prefix: &'static str) -> Result<(), StripeError> {
    if value.is_empty()
        || value.len() > 256
        || value.trim() != value
        || value.chars().any(char::is_control)
        || !value.starts_with(prefix)
        || !value[prefix.len()..]
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
    {
        return Err(StripeError::definitive(format!(
            "invalid Stripe {prefix} identifier"
        )));
    }
    Ok(())
}

fn pair(key: impl Into<String>, value: impl Into<String>) -> (String, String) {
    (key.into(), value.into())
}

fn append_checkout_placeholder(base: &str) -> String {
    if base.contains('?') {
        format!("{base}&session_id={{CHECKOUT_SESSION_ID}}")
    } else {
        format!("{base}?session_id={{CHECKOUT_SESSION_ID}}")
    }
}

fn add_payout_schedule(form: &mut Vec<(String, String)>, country: &str) {
    if country.eq_ignore_ascii_case("JP") {
        form.push(pair("settings[payouts][schedule][interval]", "weekly"));
        form.push(pair("settings[payouts][schedule][weekly_anchor]", "monday"));
    } else {
        form.push(pair("settings[payouts][schedule][interval]", "daily"));
    }
}

pub(super) fn required_service_agreement(platform_country: &str, country: &str) -> &'static str {
    let platform_country = platform_country.trim().to_ascii_uppercase();
    let country = country.trim().to_ascii_uppercase();
    if country == platform_country
        || matches!(
            country.as_str(),
            "US" | "CA"
                | "GB"
                | "AT"
                | "BE"
                | "BG"
                | "HR"
                | "CY"
                | "CZ"
                | "DK"
                | "EE"
                | "FI"
                | "FR"
                | "DE"
                | "GR"
                | "HU"
                | "IE"
                | "IT"
                | "LV"
                | "LT"
                | "LU"
                | "MT"
                | "NL"
                | "PL"
                | "PT"
                | "RO"
                | "SK"
                | "SI"
                | "ES"
                | "SE"
                | "CH"
                | "LI"
                | "NO"
                | "IS"
        )
    {
        "full"
    } else {
        "recipient"
    }
}

pub(super) fn verify_signature(
    body: &[u8],
    header: &str,
    secret: &str,
    now: SystemTime,
    tolerance: Duration,
) -> Result<Value, BillingError> {
    if secret.is_empty() {
        return Err(BillingError::unavailable(
            "Stripe webhook secret is not configured",
        ));
    }
    let mut timestamp = None;
    let mut signatures = Vec::new();
    for part in header.split(',') {
        let Some((key, value)) = part.trim().split_once('=') else {
            continue;
        };
        match key {
            "t" => {
                timestamp = Some(
                    value
                        .parse::<u64>()
                        .map_err(|_| BillingError::bad_request("invalid Stripe signature"))?,
                );
            }
            "v1" if !value.is_empty() => signatures.push(value),
            _ => {}
        }
    }
    let timestamp =
        timestamp.ok_or_else(|| BillingError::bad_request("invalid Stripe signature"))?;
    if signatures.is_empty() {
        return Err(BillingError::bad_request("invalid Stripe signature"));
    }
    let now = now
        .duration_since(UNIX_EPOCH)
        .map_err(|_| BillingError::internal("verify webhook clock", "clock before Unix epoch"))?
        .as_secs();
    if now.abs_diff(timestamp) > tolerance.as_secs() {
        return Err(BillingError::bad_request(
            "Stripe webhook timestamp is outside the accepted tolerance",
        ));
    }
    let mut signed = timestamp.to_string().into_bytes();
    signed.push(b'.');
    signed.extend_from_slice(body);
    let expected = hmac_sha256(secret.as_bytes(), &signed);
    let expected_hex = hex(&expected);
    let valid = signatures.iter().fold(false, |valid, candidate| {
        valid
            | (candidate.len() == expected_hex.len()
                && bool::from(candidate.as_bytes().ct_eq(expected_hex.as_bytes())))
    });
    if !valid {
        return Err(BillingError::bad_request("invalid Stripe signature"));
    }
    serde_json::from_slice::<Value>(body)
        .map_err(|_| BillingError::bad_request("Stripe webhook body is not valid JSON"))
        .and_then(|value| {
            if value.is_object() {
                Ok(value)
            } else {
                Err(BillingError::bad_request(
                    "Stripe webhook body must be a JSON object",
                ))
            }
        })
}

fn hmac_sha256(secret: &[u8], message: &[u8]) -> [u8; 32] {
    const BLOCK: usize = 64;
    let mut key = [0_u8; BLOCK];
    if secret.len() > BLOCK {
        key[..32].copy_from_slice(&Sha256::digest(secret));
    } else {
        key[..secret.len()].copy_from_slice(secret);
    }
    let mut inner_pad = [0x36_u8; BLOCK];
    let mut outer_pad = [0x5c_u8; BLOCK];
    for index in 0..BLOCK {
        inner_pad[index] ^= key[index];
        outer_pad[index] ^= key[index];
    }
    let mut inner = Sha256::new();
    inner.update(inner_pad);
    inner.update(message);
    let inner = inner.finalize();
    let mut outer = Sha256::new();
    outer.update(outer_pad);
    outer.update(inner);
    outer.finalize().into()
}

fn hex(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(ALPHABET[(byte >> 4) as usize] as char);
        output.push(ALPHABET[(byte & 0x0f) as usize] as char);
    }
    output
}

#[cfg(test)]
mod tests {
    use std::time::UNIX_EPOCH;

    use super::*;

    #[test]
    fn signature_uses_exact_body_and_bounded_bidirectional_timestamp() {
        let now = UNIX_EPOCH + Duration::from_secs(1_000);
        let body = br#"{"id":"evt_1","type":"test"}"#;
        let signed = [b"1000.".as_slice(), body].concat();
        let signature = hex(&hmac_sha256(b"secret", &signed));
        let header = format!("t=1000,v1={signature}");
        assert!(verify_signature(body, &header, "secret", now, WEBHOOK_TOLERANCE).is_ok());
        assert!(
            verify_signature(
                br#"{ "id":"evt_1","type":"test"}"#,
                &header,
                "secret",
                now,
                WEBHOOK_TOLERANCE
            )
            .is_err()
        );
        assert!(
            verify_signature(
                body,
                &header,
                "secret",
                now + Duration::from_secs(301),
                WEBHOOK_TOLERANCE
            )
            .is_err()
        );
        let future_signed = [b"1301.".as_slice(), body].concat();
        let future_header = format!("t=1301,v1={}", hex(&hmac_sha256(b"secret", &future_signed)));
        assert!(verify_signature(body, &future_header, "secret", now, WEBHOOK_TOLERANCE).is_err());
    }
}
