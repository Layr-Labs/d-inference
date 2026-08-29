//! Chat request parsing and one-pass normalization: alias resolution,
//! output-bound injection, trait detection, single provider-body
//! serialization (plan §15.4).

use bytes::Bytes;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use tokio::sync::mpsc;
use uuid::Uuid;

use darkbloom_core::ids::JobId;

use crate::http::errors::ApiError;
use crate::http::HttpState;
use crate::request_task::{ConsumerEvent, NormalizedRequest};

/// Ceiling injected when the consumer sets no output bound, so the
/// reservation covers the whole generation (Go `defaultMaxOutputTokens`).
const DEFAULT_MAX_OUTPUT_TOKENS: u64 = 8192;

/// The chat completions request, parsed exactly once. Unknown fields ride
/// in `extra` and are re-serialized verbatim toward the provider.
#[derive(Debug, Serialize, Deserialize)]
pub(super) struct ChatCompletionRequest {
    #[serde(default)]
    pub model: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub messages: Option<Vec<Value>>,
    #[serde(default)]
    pub stream: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_completion_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_output_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tools: Option<Value>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

impl ChatCompletionRequest {
    /// Explicit consumer bound from any recognized field (Go
    /// `explicitMaxTokens`).
    fn explicit_max_tokens(&self) -> Option<u64> {
        [
            self.max_tokens,
            self.max_completion_tokens,
            self.max_output_tokens,
        ]
        .into_iter()
        .flatten()
        .find(|v| *v > 0)
    }

    /// Routing estimate: message content bytes / 4 (Go
    /// `estimatePromptTokens` heuristic).
    fn estimated_prompt_tokens(&self) -> u64 {
        let mut bytes: u64 = 0;
        for message in self.messages.iter().flatten() {
            match message.get("content") {
                Some(Value::String(s)) => bytes += s.len() as u64,
                Some(Value::Array(parts)) => {
                    for part in parts {
                        if let Some(Value::String(s)) = part.get("text") {
                            bytes += s.len() as u64;
                        }
                    }
                }
                _ => {}
            }
        }
        (bytes / 4).max(1)
    }

    fn needs_vision(&self) -> bool {
        self.messages.iter().flatten().any(|message| {
            matches!(message.get("content"), Some(Value::Array(parts))
                if parts.iter().any(|p| p.get("type").and_then(Value::as_str) == Some("image_url")))
        })
    }

    fn needs_tools(&self) -> bool {
        matches!(&self.tools, Some(Value::Array(t)) if !t.is_empty())
    }
}

/// One normalization pass: alias resolution, bound injection, provider
/// body serialization (serialized exactly once, plan §15.4).
pub(super) struct Prepared {
    pub normalized: NormalizedRequest,
    pub stream: bool,
    pub public_model: String,
    pub job: JobId,
}

pub(super) fn prepare_request(
    state: &HttpState,
    key: &crate::contracts::ApiKeyRecord,
    body: &[u8],
    consumer: mpsc::Sender<ConsumerEvent>,
) -> Result<Prepared, ApiError> {
    let mut request: ChatCompletionRequest = serde_json::from_slice(body)
        .map_err(|_| ApiError::InvalidRequest("invalid JSON body".to_owned()))?;
    if request.model.is_empty() {
        return Err(ApiError::InvalidRequest("model is required".to_owned()));
    }
    if request.messages.as_ref().is_none_or(Vec::is_empty) {
        return Err(ApiError::InvalidRequest(
            "messages or input is required".to_owned(),
        ));
    }

    let catalog = state.app.catalog.load();
    let public_model = request.model.clone();
    let concrete_model = if let Some(concrete) = catalog.aliases.get(&public_model) {
        concrete.clone()
    } else if catalog.prices.contains_key(&public_model) {
        public_model.clone()
    } else {
        return Err(ApiError::ModelNotFound(public_model));
    };

    let requested_max = request
        .explicit_max_tokens()
        .unwrap_or(DEFAULT_MAX_OUTPUT_TOKENS);
    // Bound injection (Go ensureMaxTokensBound): the provider must see the
    // same ceiling the reservation covers.
    request.max_tokens = Some(requested_max);
    let estimated_prompt_tokens = request.estimated_prompt_tokens();
    let needs_vision = request.needs_vision();
    let needs_tools = request.needs_tools();
    let stream = request.stream;

    // Rewrite to the concrete build and serialize the provider body once.
    request.model = concrete_model.clone();
    let provider_body = serde_json::to_vec(&request)
        .map_err(|_| ApiError::Internal("failed to serialize provider body"))?;

    let job = JobId::new(Uuid::new_v4());
    Ok(Prepared {
        normalized: NormalizedRequest {
            job,
            account: key.account,
            api_key: key.key_id.clone(),
            spend_cap: key.spend_cap,
            public_model: public_model.clone(),
            concrete_model,
            body: Bytes::from(provider_body),
            stream,
            estimated_prompt_tokens,
            requested_max_tokens: requested_max,
            needs_vision,
            needs_tools,
            paid: true,
            consumer,
        },
        stream,
        public_model,
        job,
    })
}
