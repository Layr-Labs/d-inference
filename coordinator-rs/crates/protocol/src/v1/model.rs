use serde::{Deserialize, Serialize};

use crate::v1::JsonNumber;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModelInfo {
    pub id: String,
    pub size_bytes: u64,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub model_type: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub quantization: String,
    #[serde(default, skip_serializing_if = "JsonNumber::is_zero")]
    pub estimated_memory_gb: JsonNumber,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub weight_hash: String,
    #[serde(default, skip_serializing_if = "is_false")]
    pub is_vision: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub template_render_ok: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LoadModel {
    pub model_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LoadModelStatus {
    pub model_id: String,
    pub status: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub error: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrefetchModel {
    pub model_id: String,
    #[serde(default, skip_serializing_if = "is_zero_i32")]
    pub priority: i32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrefetchModelStatus {
    pub model_id: String,
    pub status: String,
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub bytes_done: u64,
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub bytes_total: u64,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub error: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DesiredModelEntry {
    pub model_name: String,
    pub desired_build: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub previous_build: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DesiredModels {
    pub models: Vec<DesiredModelEntry>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModelsUpdate {
    pub models: Vec<ModelInfo>,
}

pub type LoadModelMessage = LoadModel;
pub type LoadModelStatusMessage = LoadModelStatus;
pub type PrefetchModelMessage = PrefetchModel;
pub type PrefetchModelStatusMessage = PrefetchModelStatus;
pub type DesiredModelsMessage = DesiredModels;
pub type ModelsUpdateMessage = ModelsUpdate;

const fn is_false(value: &bool) -> bool {
    !*value
}

const fn is_zero_i32(value: &i32) -> bool {
    *value == 0
}

const fn is_zero_u64(value: &u64) -> bool {
    *value == 0
}
