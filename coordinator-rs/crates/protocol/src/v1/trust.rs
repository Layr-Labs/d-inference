use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttestationChallenge {
    pub nonce: String,
    pub timestamp: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttestationResponse {
    pub nonce: String,
    pub signature: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub status_signature: String,
    pub public_key: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hypervisor_active: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rdma_disabled: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sip_enabled: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub secure_boot_enabled: Option<bool>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub binary_hash: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub active_model_hash: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub python_hash: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub runtime_hash: String,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub template_hashes: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub grpc_binary_hash: String,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub model_hashes: BTreeMap<String, String>,
}

impl AttestationResponse {
    /// Rebuilds the exact deterministic bytes covered by `status_signature`.
    pub fn canonical_status_bytes(&self, timestamp: &str) -> Result<Vec<u8>, serde_json::Error> {
        AttestationStatus {
            nonce: self.nonce.clone(),
            timestamp: timestamp.to_owned(),
            hypervisor_active: self.hypervisor_active,
            rdma_disabled: self.rdma_disabled,
            sip_enabled: self.sip_enabled,
            secure_boot_enabled: self.secure_boot_enabled,
            binary_hash: self.binary_hash.clone(),
            active_model_hash: self.active_model_hash.clone(),
            python_hash: self.python_hash.clone(),
            runtime_hash: self.runtime_hash.clone(),
            template_hashes: self.template_hashes.clone(),
            grpc_binary_hash: self.grpc_binary_hash.clone(),
            model_hashes: self.model_hashes.clone(),
        }
        .canonical_bytes()
    }
}

/// Inputs to the status-signature canonical byte contract.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AttestationStatus {
    pub nonce: String,
    pub timestamp: String,
    pub hypervisor_active: Option<bool>,
    pub rdma_disabled: Option<bool>,
    pub sip_enabled: Option<bool>,
    pub secure_boot_enabled: Option<bool>,
    pub binary_hash: String,
    pub active_model_hash: String,
    pub python_hash: String,
    pub runtime_hash: String,
    pub template_hashes: BTreeMap<String, String>,
    pub grpc_binary_hash: String,
    pub model_hashes: BTreeMap<String, String>,
}

impl AttestationStatus {
    pub fn canonical_bytes(&self) -> Result<Vec<u8>, serde_json::Error> {
        let mut fields = BTreeMap::new();
        fields.insert("nonce", self.nonce.clone().into());
        fields.insert("timestamp", self.timestamp.clone().into());
        if let Some(value) = self.hypervisor_active {
            fields.insert("hypervisor_active", value.into());
        }
        if let Some(value) = self.rdma_disabled {
            fields.insert("rdma_disabled", value.into());
        }
        if let Some(value) = self.sip_enabled {
            fields.insert("sip_enabled", value.into());
        }
        if let Some(value) = self.secure_boot_enabled {
            fields.insert("secure_boot_enabled", value.into());
        }
        insert_nonempty(&mut fields, "binary_hash", &self.binary_hash);
        insert_nonempty(&mut fields, "active_model_hash", &self.active_model_hash);
        insert_nonempty(&mut fields, "python_hash", &self.python_hash);
        insert_nonempty(&mut fields, "runtime_hash", &self.runtime_hash);
        if !self.template_hashes.is_empty() {
            fields.insert(
                "template_hashes",
                serde_json::to_value(&self.template_hashes)?,
            );
        }
        insert_nonempty(&mut fields, "grpc_binary_hash", &self.grpc_binary_hash);
        if !self.model_hashes.is_empty() {
            fields.insert("model_hashes", serde_json::to_value(&self.model_hashes)?);
        }
        serde_json::to_vec(&fields)
    }
}

fn insert_nonempty(
    fields: &mut BTreeMap<&'static str, serde_json::Value>,
    key: &'static str,
    value: &str,
) {
    if !value.is_empty() {
        fields.insert(key, value.to_owned().into());
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CodeAttestationResponse {
    pub nonce: String,
    pub signature: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RuntimeMismatch {
    pub component: String,
    pub expected: String,
    pub got: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RuntimeStatus {
    pub verified: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub mismatches: Vec<RuntimeMismatch>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TrustStatus {
    pub trust_level: String,
    pub status: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub reason: String,
}

pub type AttestationChallengeMessage = AttestationChallenge;
pub type AttestationResponseMessage = AttestationResponse;
pub type CodeAttestationResponseMessage = CodeAttestationResponse;
pub type RuntimeStatusMessage = RuntimeStatus;
pub type TrustStatusMessage = TrustStatus;
