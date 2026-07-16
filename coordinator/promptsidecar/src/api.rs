use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Endpoint {
    ChatCompletions,
    Completions,
    Responses,
    Messages,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PlanRequest {
    pub prompt_contract_id: String,
    pub scope_id: String,
    pub endpoint: Endpoint,
    pub body: Value,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BlockBoundary {
    pub token_count: u32,
    pub chain_hash: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct PlanResponse {
    pub prompt_contract_id: String,
    pub prompt_token_count: u32,
    pub block_boundaries: Vec<BlockBoundary>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_complete_block_hash: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct ErrorResponse {
    pub error: ErrorBody,
}

#[derive(Clone, Debug, Serialize)]
pub struct ErrorBody {
    pub code: &'static str,
    pub message: &'static str,
}

impl ErrorResponse {
    pub fn new(code: &'static str, message: &'static str) -> Self {
        Self {
            error: ErrorBody { code, message },
        }
    }
}
