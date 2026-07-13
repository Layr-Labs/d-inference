//! Runtime enforcement for finite Datadog tag dimensions.

use std::borrow::Cow;

pub(super) const MAX_TAG_VALUE_BYTES: usize = 64;

/// Closed set of bounded-cardinality tag dimensions.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TagKey {
    Stage,
    Outcome,
    Reason,
    State,
    Operation,
    Lane,
    Trust,
    ProviderVersion,
    Route,
    Method,
    StatusClass,
    Kind,
    Source,
    Schema,
    Mode,
}

impl TagKey {
    pub(super) const fn as_str(self) -> &'static str {
        match self {
            Self::Stage => "stage",
            Self::Outcome => "outcome",
            Self::Reason => "reason",
            Self::State => "state",
            Self::Operation => "operation",
            Self::Lane => "lane",
            Self::Trust => "trust",
            Self::ProviderVersion => "provider_version",
            Self::Route => "route",
            Self::Method => "method",
            Self::StatusClass => "status_class",
            Self::Kind => "kind",
            Self::Source => "source",
            Self::Schema => "schema",
            Self::Mode => "mode",
        }
    }
}

/// One sanitized low-cardinality tag.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Tag {
    pub(super) key: TagKey,
    pub(super) value: Cow<'static, str>,
}

impl Tag {
    #[must_use]
    pub fn new(key: TagKey, value: impl Into<Cow<'static, str>>) -> Self {
        let mut value = value.into();
        if key == TagKey::Operation && value.contains(' ') {
            value = Cow::Owned(value.replace(' ', "_"));
        }
        if allowed_value(key, &value) {
            Self { key, value }
        } else {
            Self {
                key,
                value: Cow::Borrowed("other"),
            }
        }
    }
}

pub(super) fn valid_value(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_TAG_VALUE_BYTES
        && value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.' | b'/' | b':')
        })
}

fn allowed_value(key: TagKey, value: &str) -> bool {
    if !valid_value(value) {
        return false;
    }
    match key {
        TagKey::Stage => matches!(
            value,
            "auth"
                | "chunk"
                | "other"
                | "parse"
                | "prepare"
                | "release"
                | "reserve"
                | "settle"
                | "start"
                | "terminal"
                | "total"
                | "ttft"
        ),
        TagKey::Outcome => matches!(
            value,
            "applied"
                | "at_or_above_floor"
                | "below_floor"
                | "cancelled"
                | "current"
                | "delivered"
                | "established"
                | "failed"
                | "failure"
                | "ignored"
                | "invalid"
                | "newer"
                | "on_wire"
                | "older_supported"
                | "other"
                | "projected"
                | "rejected"
                | "retry"
                | "saturated"
                | "sent_unknown"
                | "stale"
                | "success"
                | "unconfigured"
        ),
        TagKey::Reason => matches!(
            value,
            "capacity"
                | "capacity_policy"
                | "draining"
                | "eligible"
                | "fleet_state"
                | "invalid_lease_ttl"
                | "lease_limit"
                | "lease_not_found"
                | "model_mismatch"
                | "no_eligible_provider"
                | "other"
                | "permit_active"
                | "provider_busy"
                | "provider_limit"
                | "provider_not_found"
                | "session_error"
                | "stale_fence"
                | "writer_bytes"
                | "writer_items"
                | "writer_reservation_limit"
        ),
        TagKey::State => matches!(
            value,
            "conflict"
                | "failed"
                | "not_sent"
                | "on_wire"
                | "other"
                | "pending"
                | "prepared"
                | "preparing"
                | "processing"
                | "queued"
                | "reserved"
                | "review_pending"
                | "running"
                | "sent_unknown"
                | "start_authorized"
                | "started"
                | "terminal_recorded"
        ),
        TagKey::Operation => matches!(
            value,
            "await_terminal"
                | "billing"
                | "external-event_recovery"
                | "fee_projection"
                | "fee_projection_outbox"
                | "job_recovery"
                | "ledger"
                | "other"
                | "outbox_recovery"
                | "reconcile_authorized"
                | "recovery"
                | "release"
                | "release_not_sent"
                | "release_pre_authorization"
                | "reserve"
                | "resize"
                | "settle"
                | "start"
                | "state_snapshot"
                | "terminal"
                | "terminal_quarantine"
                | "terminal_recovery"
        ),
        TagKey::Lane => matches!(value, "control" | "data" | "other"),
        TagKey::Trust => {
            matches!(
                value,
                "hardware" | "other" | "self_signed" | "unknown" | "untrusted"
            )
        }
        TagKey::ProviderVersion => matches!(
            value,
            "at_or_above_floor"
                | "below_floor"
                | "current"
                | "invalid"
                | "newer"
                | "older_supported"
                | "other"
                | "unconfigured"
        ),
        TagKey::Route => {
            matches!(value, "other" | "unmatched")
                || (value.starts_with('/')
                    && value
                        .split('/')
                        .all(|segment| !looks_like_dynamic_identifier(segment)))
        }
        TagKey::Method => matches!(
            value,
            "DELETE" | "GET" | "HEAD" | "OPTIONS" | "OTHER" | "PATCH" | "POST" | "PUT" | "other"
        ),
        TagKey::StatusClass => {
            matches!(value, "2xx" | "3xx" | "4xx" | "5xx" | "other")
        }
        TagKey::Kind => matches!(
            value,
            "bytes"
                | "diagnostics"
                | "external"
                | "external_event"
                | "fee"
                | "fee_allocations"
                | "fee_projection_checkpoints"
                | "financial_operations"
                | "inference"
                | "inference_attempts"
                | "inference_jobs"
                | "items"
                | "job"
                | "mdm_command_expectations"
                | "mutation"
                | "other"
                | "outbox"
                | "privy"
                | "privy_or_api_key"
                | "provider_terminals"
                | "provider_token"
                | "receipt"
                | "send"
                | "telemetry_events"
                | "terminal"
        ),
        TagKey::Source => matches!(value, "other" | "stripe"),
        TagKey::Schema => matches!(value, "other" | "public" | "rust"),
        TagKey::Mode => {
            matches!(
                value,
                "go_fallback" | "handoff" | "inference" | "other" | "status"
            )
        }
    }
}

fn looks_like_dynamic_identifier(segment: &str) -> bool {
    if segment.starts_with(':') {
        return false;
    }
    let uuid_like = segment.len() >= 16
        && segment.matches('-').count() >= 2
        && segment
            .chars()
            .all(|character| character.is_ascii_hexdigit() || character == '-');
    uuid_like || segment.contains('@')
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use serde_json::Value;

    use super::*;

    #[test]
    fn tag_keys_exclude_sensitive_and_unbounded_dimensions() {
        let keys = [
            TagKey::Stage,
            TagKey::Outcome,
            TagKey::Reason,
            TagKey::State,
            TagKey::Operation,
            TagKey::Lane,
            TagKey::Trust,
            TagKey::ProviderVersion,
            TagKey::Route,
            TagKey::Method,
            TagKey::StatusClass,
            TagKey::Kind,
            TagKey::Source,
            TagKey::Schema,
            TagKey::Mode,
        ];
        for key in keys {
            assert!(!matches!(
                key.as_str(),
                "prompt"
                    | "account"
                    | "account_id"
                    | "key"
                    | "key_id"
                    | "provider"
                    | "provider_id"
                    | "request_id"
            ));
        }
    }

    #[test]
    fn unknown_or_unbounded_values_collapse_instead_of_expanding_cardinality() {
        assert_eq!(
            Tag::new(TagKey::Reason, "safe_but_not_catalogued").value,
            Cow::Borrowed("other")
        );
        assert_eq!(
            Tag::new(TagKey::Reason, "eligible").value,
            Cow::Borrowed("eligible")
        );
        assert_eq!(
            Tag::new(TagKey::Operation, "terminal recovery")
                .value
                .as_ref(),
            "terminal_recovery"
        );
        assert_eq!(
            Tag::new(TagKey::ProviderVersion, "99.100.101").value,
            Cow::Borrowed("other")
        );
        assert_eq!(
            Tag::new(TagKey::Route, "/v1/keys/31c99ec9-97d2-445f-9ae2").value,
            Cow::Borrowed("other")
        );
        assert_eq!(
            Tag::new(TagKey::Route, "/v1/keys/:id").value,
            Cow::Borrowed("/v1/keys/:id")
        );
    }

    #[test]
    fn runtime_accepts_every_committed_allowlist_value() {
        let allowlist: Value = serde_json::from_str(include_str!(
            "../../../../../../deploy/datadog/rust-metrics-allowlist.json"
        ))
        .expect("Datadog allowlist");
        let values = allowlist["tag_values"]
            .as_object()
            .expect("tag value catalog");
        let keys = BTreeMap::from([
            ("stage", TagKey::Stage),
            ("outcome", TagKey::Outcome),
            ("reason", TagKey::Reason),
            ("state", TagKey::State),
            ("operation", TagKey::Operation),
            ("lane", TagKey::Lane),
            ("trust", TagKey::Trust),
            ("provider_version", TagKey::ProviderVersion),
            ("method", TagKey::Method),
            ("status_class", TagKey::StatusClass),
            ("kind", TagKey::Kind),
            ("source", TagKey::Source),
            ("schema", TagKey::Schema),
            ("mode", TagKey::Mode),
        ]);
        for (name, key) in keys {
            for value in values[name].as_array().expect("finite tag value list") {
                let value = value.as_str().expect("tag value");
                assert!(allowed_value(key, value), "{name}:{value}");
            }
        }

        let routes: Value = serde_json::from_str(include_str!(
            "../../../../../../tests/contracts/http/routes.json"
        ))
        .expect("HTTP route contract");
        for route in routes["routes"].as_array().expect("routes") {
            let normalized = route["path"]
                .as_str()
                .expect("route path")
                .replace('{', ":")
                .replace('}', "");
            assert!(
                allowed_value(TagKey::Route, &normalized),
                "route:{normalized}"
            );
        }
    }
}
