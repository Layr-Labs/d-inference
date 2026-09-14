package protocol

import (
	"encoding/json"
)

// CPUCores describes the CPU core layout.
type CPUCores struct {
	Total       int `json:"total"`
	Performance int `json:"performance"`
	Efficiency  int `json:"efficiency"`
}

// Hardware describes the provider's machine capabilities.
type Hardware struct {
	MachineModel       string   `json:"machine_model"`
	ChipName           string   `json:"chip_name"`
	ChipFamily         string   `json:"chip_family"`
	ChipTier           string   `json:"chip_tier"`
	MemoryGB           int      `json:"memory_gb"`
	MemoryAvailableGB  float64  `json:"memory_available_gb"`
	CPUCores           CPUCores `json:"cpu_cores"`
	GPUCores           int      `json:"gpu_cores"`
	MemoryBandwidthGBs float64  `json:"memory_bandwidth_gbs"`
}

// RegisterMessage is sent when a provider first connects.
type RegisterMessage struct {
	Type                        string                             `json:"type"`
	Hardware                    Hardware                           `json:"hardware"`
	Models                      []ModelInfo                        `json:"models"`
	Backend                     string                             `json:"backend"`
	RuntimeCapabilities         []string                           `json:"runtime_capabilities,omitempty"`      // connection-scoped hardware/runtime capabilities
	Version                     string                             `json:"version,omitempty"`                   // provider binary version (e.g. "0.2.31")
	PublicKey                   string                             `json:"public_key,omitempty"`                // base64-encoded X25519 public key for E2E encryption
	EncryptedResponseChunks     bool                               `json:"encrypted_response_chunks,omitempty"` // true when text response chunks are returned encrypted to the coordinator
	Attestation                 json.RawMessage                    `json:"attestation,omitempty"`               // signed Secure Enclave attestation blob
	PrefillTPS                  float64                            `json:"prefill_tps,omitempty"`               // benchmark: prefill tokens per second
	DecodeTPS                   float64                            `json:"decode_tps,omitempty"`                // benchmark: decode tokens per second
	AuthToken                   string                             `json:"auth_token,omitempty"`                // device-linked provider token (from darkbloom login)
	PrivateOnly                 bool                               `json:"private_only,omitempty"`              // when true, this machine serves only its owner's self-route requests, never the public fleet
	PrefixCacheProtocol         int                                `json:"prefix_cache_protocol,omitempty"`     // provider-confirmed prefix-cache protocol version
	PrefixCacheV2Models         []PrefixCacheV2Capability          `json:"prefix_cache_v2_models,omitempty"`
	PrefixCacheMemoryModels     []PrefixCacheV2Capability          `json:"prefix_cache_memory_models,omitempty"`
	PrefixCacheStatuses         *[]PrefixCacheModelStatus          `json:"prefix_cache_statuses,omitempty"`
	PrefixCacheDonationOutcomes *[]PrefixCacheDonationOutcomeCount `json:"prefix_cache_donation_outcomes,omitempty"`
	ToolConstraintProtocol      int                                `json:"tool_constraint_protocol,omitempty"` // inference-time forced-tool enforcement protocol version
	ToolConstraintModels        []string                           `json:"tool_constraint_models,omitempty"`   // concrete model IDs enforced by this provider

	// APNs code-identity attestation (v0.6.0): the device token the coordinator
	// pushes the E_K(nonce) code-identity challenge to, and which APNs environment
	// that token belongs to. Bound 1:1 to PublicKey (K) at registration.
	APNsDeviceToken string `json:"apns_device_token,omitempty"` // hex device token from registerForRemoteNotifications
	APNsEnvironment string `json:"apns_environment,omitempty"`  // "production" | "development" (selects the APNs host)

	// Runtime integrity hashes — used for runtime verification against known-good manifests.
	PythonHash          string               `json:"python_hash,omitempty"`     // SHA-256 of Python runtime
	RuntimeHash         string               `json:"runtime_hash,omitempty"`    // SHA-256 of inference runtime (MLX-Swift)
	TemplateHashes      map[string]string    `json:"template_hashes,omitempty"` // template_name -> SHA-256 hash
	PrivacyCapabilities *PrivacyCapabilities `json:"privacy_capabilities,omitempty"`
}

// PrivacyCapabilities describes the provider's privacy invariants at registration time.
//
// Note: legacy providers (< v0.6.31) also send a `hypervisor_active` key here.
// The concept is retired (Darkbloom never uses hypervisors — it was a
// hardcoded-false stub) and is intentionally not modeled; encoding/json drops
// unknown fields, so old providers remain wire-compatible.
type PrivacyCapabilities struct {
	TextBackendInprocess    bool `json:"text_backend_inprocess"`
	TextProxyDisabled       bool `json:"text_proxy_disabled"`
	PythonRuntimeLocked     bool `json:"python_runtime_locked"`
	DangerousModulesBlocked bool `json:"dangerous_modules_blocked"`
	SIPEnabled              bool `json:"sip_enabled"`
	AntiDebugEnabled        bool `json:"anti_debug_enabled"`
	CoreDumpsDisabled       bool `json:"core_dumps_disabled"`
	EnvScrubbed             bool `json:"env_scrubbed"`
}
