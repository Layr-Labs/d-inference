package main

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type wireCase struct {
	Name        string `json:"name"`
	MessageType string `json:"message_type"`
	Wire        string `json:"wire"`
	ExactBytes  bool   `json:"exact_bytes"`
	Notes       string `json:"notes,omitempty"`
}

type wireContract struct {
	SchemaVersion int        `json:"schema_version"`
	Direction     string     `json:"direction"`
	Encoding      string     `json:"encoding"`
	Cases         []wireCase `json:"cases"`
}

// providerRegisterContract mirrors the Swift provider's emitted register
// shape, including estimated_memory_gb, which Go intentionally ignores.
type providerRegisterContract struct {
	Type                    string                        `json:"type"`
	Hardware                protocol.Hardware             `json:"hardware"`
	Models                  []providerModelInfoContract   `json:"models"`
	Backend                 string                        `json:"backend"`
	Version                 string                        `json:"version,omitempty"`
	PublicKey               string                        `json:"public_key,omitempty"`
	EncryptedResponseChunks bool                          `json:"encrypted_response_chunks,omitempty"`
	Attestation             json.RawMessage               `json:"attestation,omitempty"`
	PrefillTPS              float64                       `json:"prefill_tps,omitempty"`
	DecodeTPS               float64                       `json:"decode_tps,omitempty"`
	AuthToken               string                        `json:"auth_token,omitempty"`
	PrivateOnly             bool                          `json:"private_only,omitempty"`
	APNsDeviceToken         string                        `json:"apns_device_token,omitempty"`
	APNsEnvironment         string                        `json:"apns_environment,omitempty"`
	RuntimeHash             string                        `json:"runtime_hash,omitempty"`
	TemplateHashes          map[string]string             `json:"template_hashes,omitempty"`
	PrivacyCapabilities     *protocol.PrivacyCapabilities `json:"privacy_capabilities,omitempty"`
}

type providerModelInfoContract struct {
	ID                string  `json:"id"`
	SizeBytes         int64   `json:"size_bytes"`
	ModelType         string  `json:"model_type,omitempty"`
	Quantization      string  `json:"quantization,omitempty"`
	EstimatedMemoryGB float64 `json:"estimated_memory_gb"`
	WeightHash        string  `json:"weight_hash,omitempty"`
	IsVision          bool    `json:"is_vision,omitempty"`
	TemplateRenderOK  *bool   `json:"template_render_ok,omitempty"`
}

type providerModelsUpdateContract struct {
	Type   string                      `json:"type"`
	Models []providerModelInfoContract `json:"models"`
}

func generateProtocol(_ string) (map[string][]byte, error) {
	providerCases, err := providerProtocolCases()
	if err != nil {
		return nil, err
	}
	coordinatorCases, err := coordinatorProtocolCases()
	if err != nil {
		return nil, err
	}

	providerContract, err := json.MarshalIndent(wireContract{
		SchemaVersion: 1,
		Direction:     "provider_to_coordinator",
		Encoding:      "json_text",
		Cases:         providerCases,
	}, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("marshal provider protocol contract: %w", err)
	}
	coordinatorContract, err := json.MarshalIndent(wireContract{
		SchemaVersion: 1,
		Direction:     "coordinator_to_provider",
		Encoding:      "json_text",
		Cases:         coordinatorCases,
	}, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("marshal coordinator protocol contract: %w", err)
	}

	return map[string][]byte{
		"tests/contracts/protocol/v1/provider_to_coordinator.json": providerContract,
		"tests/contracts/protocol/v1/coordinator_to_provider.json": coordinatorContract,
		"docs/reference/provider-protocol-v1.md":                   []byte(renderProtocolInventory(providerCases, coordinatorCases)),
	}, nil
}

func providerProtocolCases() ([]wireCase, error) {
	templateOK := false
	activeModel := "model-a"
	trueValue := true
	falseValue := false
	fullHardware := protocol.Hardware{
		MachineModel:       "Mac15,8",
		ChipName:           "Apple M3 Max",
		ChipFamily:         "M3",
		ChipTier:           "Max",
		MemoryGB:           64,
		MemoryAvailableGB:  58,
		CPUCores:           protocol.CPUCores{Total: 16, Performance: 12, Efficiency: 4},
		GPUCores:           40,
		MemoryBandwidthGBs: 400,
	}

	values := []struct {
		name        string
		messageType string
		value       any
		exact       bool
		notes       string
	}{
		{
			name:        "register_minimal",
			messageType: protocol.TypeRegister,
			value: providerRegisterContract{
				Type: protocol.TypeRegister, Hardware: fullHardware,
				Models: []providerModelInfoContract{}, Backend: "mlx-swift",
			},
			notes: "Optional fields are omitted.",
		},
		{
			name:        "register_full_raw_attestation",
			messageType: protocol.TypeRegister,
			value: providerRegisterContract{
				Type:     protocol.TypeRegister,
				Hardware: fullHardware,
				Models: []providerModelInfoContract{{
					ID: "model-a", SizeBytes: 123456789, ModelType: "chat",
					Quantization: "4bit", EstimatedMemoryGB: 16,
					WeightHash: "weight-sha256", IsVision: true, TemplateRenderOK: &templateOK,
				}},
				Backend: "mlx-swift", Version: "0.7.5", PublicKey: "provider-x25519",
				EncryptedResponseChunks: true,
				Attestation:             json.RawMessage(`{"signature":"sig","attestation":{"z":1,"a":[true,false]}}`),
				PrefillTPS:              321.5,
				DecodeTPS:               42.25,
				AuthToken:               "provider-token",
				PrivateOnly:             true,
				APNsDeviceToken:         "device-token",
				APNsEnvironment:         "production",
				RuntimeHash:             "runtime-sha256",
				TemplateHashes:          map[string]string{"mlx_metallib": "template-sha256"},
				PrivacyCapabilities: &protocol.PrivacyCapabilities{
					TextBackendInprocess: true, TextProxyDisabled: true, PythonRuntimeLocked: true,
					DangerousModulesBlocked: true, SIPEnabled: true, AntiDebugEnabled: true,
					CoreDumpsDisabled: true, EnvScrubbed: true,
				},
			},
			exact: true,
			notes: "The nested attestation value is signed; consumers must preserve its exact raw bytes.",
		},
		{
			name:        "heartbeat_no_active_model",
			messageType: protocol.TypeHeartbeat,
			value: protocol.HeartbeatMessage{
				Type: protocol.TypeHeartbeat, Status: "idle", ActiveModel: nil,
				Stats:         protocol.HeartbeatStats{},
				SystemMetrics: protocol.SystemMetrics{ThermalState: "nominal"},
			},
			notes: "Go emits active_model:null; decoders must also accept omission from Swift.",
		},
		{
			name:        "heartbeat_full",
			messageType: protocol.TypeHeartbeat,
			value: protocol.HeartbeatMessage{
				Type: protocol.TypeHeartbeat, Status: "serving", ActiveModel: &activeModel,
				WarmModels: []string{"model-a"},
				Stats: protocol.HeartbeatStats{
					RequestsServed: 11, TokensGenerated: 22, CancellationsReceived: 3,
					CancellationsBeforeOutput: 4, CancellationsPartialComplete: 5,
					GenerationErrorsAfterOutput: 6, ChunkEncryptionErrors: 7,
					StreamClosedWithoutTerminal: 8, CancelDuringModelLoad: 9, UsageGaps: 10,
				},
				SystemMetrics: protocol.SystemMetrics{MemoryPressure: 0.2, CPUUsage: 0.3, ThermalState: "nominal"},
				BackendCapacity: &protocol.BackendCapacity{
					Slots: []protocol.BackendSlotCapacity{{
						Model: "model-a", State: "idle", MaxConcurrency: 4,
						ActiveTokenBudgetUsed: 1024, ActiveTokenBudgetMax: 32768,
						KVBytesPerToken: 393216, ObservedDecodeTPS: 42.25,
					}},
					GPUMemoryActiveGB: 8, GPUMemoryPeakGB: 9, GPUMemoryCacheGB: 1,
					TotalMemoryGB: 64, FreeForLoadGB: float64Pointer(20.5),
				},
				APNsDeviceToken: "rotated-token", APNsEnvironment: "production",
			},
		},
		{
			name: "inference_accepted", messageType: protocol.TypeInferenceAccepted,
			value: protocol.InferenceAcceptedMessage{Type: protocol.TypeInferenceAccepted, RequestID: "request-a"},
		},
		{
			name: "inference_response_chunk_plain", messageType: protocol.TypeInferenceResponseChunk,
			value: protocol.InferenceResponseChunkMessage{
				Type: protocol.TypeInferenceResponseChunk, RequestID: "request-a",
				Data: "data: {\"choices\":[]}\n\n",
			},
		},
		{
			name: "inference_response_chunk_encrypted", messageType: protocol.TypeInferenceResponseChunk,
			value: protocol.InferenceResponseChunkMessage{
				Type: protocol.TypeInferenceResponseChunk, RequestID: "request-a",
				EncryptedData: &protocol.EncryptedPayload{EphemeralPublicKey: "sender-key", Ciphertext: "nonce-and-box"},
			},
		},
		{
			name: "inference_complete", messageType: protocol.TypeInferenceComplete,
			value: protocol.InferenceCompleteMessage{
				Type: protocol.TypeInferenceComplete, RequestID: "request-a",
				Usage:       protocol.UsageInfo{PromptTokens: 12, CompletionTokens: 34, ReasoningTokens: 5},
				SESignature: "se-signature", ResponseHash: "response-sha256",
			},
		},
		{
			name: "inference_error", messageType: protocol.TypeInferenceError,
			value: protocol.InferenceErrorMessage{
				Type: protocol.TypeInferenceError, RequestID: "request-a",
				Error: "model unavailable", StatusCode: 503, ErrorReason: "model_load",
			},
		},
		{
			name: "attestation_response_current", messageType: protocol.TypeAttestationResponse,
			value: protocol.AttestationResponseMessage{
				Type: protocol.TypeAttestationResponse, Nonce: "nonce", Signature: "signature",
				StatusSignature: "status-signature", PublicKey: "se-public-key",
				RDMADisabled: &trueValue, SIPEnabled: &trueValue, SecureBootEnabled: &trueValue,
				BinaryHash: "binary-sha256", ActiveModelHash: "model-sha256",
				RuntimeHash: "runtime-sha256", TemplateHashes: map[string]string{"chat": "template-sha256"},
				ModelHashes: map[string]string{"model-a": "model-sha256"},
			},
		},
		{
			name: "attestation_response_legacy_hypervisor_false", messageType: protocol.TypeAttestationResponse,
			value: protocol.AttestationResponseMessage{
				Type: protocol.TypeAttestationResponse, Nonce: "nonce", Signature: "signature",
				PublicKey: "se-public-key", HypervisorActive: &falseValue,
			},
			notes: "Legacy signed payload compatibility; explicit false must survive decoding.",
		},
		{
			name: "code_attestation_response", messageType: protocol.TypeCodeAttestationResponse,
			value: protocol.CodeAttestationResponseMessage{
				Type: protocol.TypeCodeAttestationResponse, Nonce: "nonce", Signature: "signature",
			},
		},
		{
			name: "load_model_status_started", messageType: protocol.TypeLoadModelStatus,
			value: protocol.LoadModelStatusMessage{
				Type: protocol.TypeLoadModelStatus, ModelID: "model-a", Status: protocol.LoadModelStatusStarted,
			},
		},
		{
			name: "load_model_status_failed", messageType: protocol.TypeLoadModelStatus,
			value: protocol.LoadModelStatusMessage{
				Type: protocol.TypeLoadModelStatus, ModelID: "model-a",
				Status: protocol.LoadModelStatusFailed, Error: protocol.ProviderDrainingForUpdate,
			},
		},
		{
			name: "prefetch_model_status_downloading", messageType: protocol.TypePrefetchModelStatus,
			value: protocol.PrefetchModelStatusMessage{
				Type: protocol.TypePrefetchModelStatus, ModelID: "model-a",
				Status: protocol.PrefetchModelStatusDownloading, BytesDone: 1024, BytesTotal: 4096,
			},
		},
		{
			name: "prefetch_model_status_verified", messageType: protocol.TypePrefetchModelStatus,
			value: protocol.PrefetchModelStatusMessage{
				Type: protocol.TypePrefetchModelStatus, ModelID: "model-a", Status: protocol.PrefetchModelStatusVerified,
			},
			notes: "Zero progress and empty error fields are omitted.",
		},
		{
			name: "models_update", messageType: protocol.TypeModelsUpdate,
			value: providerModelsUpdateContract{
				Type: protocol.TypeModelsUpdate,
				Models: []providerModelInfoContract{{
					ID: "model-a", SizeBytes: 123456789, ModelType: "chat",
					Quantization: "4bit", EstimatedMemoryGB: 16, WeightHash: "weight-sha256",
				}},
			},
		},
	}
	return marshalWireCases(values)
}

func coordinatorProtocolCases() ([]wireCase, error) {
	maxTokens := 256
	temperature := 0.25
	values := []struct {
		name        string
		messageType string
		value       any
		exact       bool
		notes       string
	}{
		{
			name: "inference_request_plain", messageType: protocol.TypeInferenceRequest,
			value: protocol.InferenceRequestMessage{
				Type: protocol.TypeInferenceRequest, RequestID: "request-a",
				Body: protocol.InferenceRequestBody{
					Model: "model-a", Messages: []protocol.ChatMessage{{Role: "user", Content: "hello"}},
					Stream: true, MaxTokens: &maxTokens, Temperature: &temperature,
					Endpoint: "/v1/chat/completions",
				},
			},
		},
		{
			name: "inference_request_encrypted", messageType: protocol.TypeInferenceRequest,
			value: protocol.InferenceRequestMessage{
				Type: protocol.TypeInferenceRequest, RequestID: "request-a",
				EncryptedBody: &protocol.EncryptedPayload{EphemeralPublicKey: "sender-key", Ciphertext: "nonce-and-box"},
			},
			notes: "The zero-value Go body is present for v1 compatibility; Swift also accepts body:null.",
		},
		{
			name: "cancel", messageType: protocol.TypeCancel,
			value: protocol.CancelMessage{Type: protocol.TypeCancel, RequestID: "request-a"},
		},
		{
			name: "attestation_challenge", messageType: protocol.TypeAttestationChallenge,
			value: protocol.AttestationChallengeMessage{
				Type: protocol.TypeAttestationChallenge, Nonce: "nonce", Timestamp: "2026-07-10T00:00:00Z",
			},
		},
		{
			name: "runtime_status_verified", messageType: protocol.TypeRuntimeStatus,
			value: protocol.RuntimeStatusMessage{Type: protocol.TypeRuntimeStatus, Verified: true},
			notes: "Empty mismatches are omitted.",
		},
		{
			name: "runtime_status_mismatch", messageType: protocol.TypeRuntimeStatus,
			value: protocol.RuntimeStatusMessage{
				Type: protocol.TypeRuntimeStatus, Verified: false,
				Mismatches: []protocol.RuntimeMismatch{{Component: "runtime", Expected: "good", Got: "bad"}},
			},
		},
		{
			name: "load_model", messageType: protocol.TypeLoadModel,
			value: protocol.LoadModelMessage{Type: protocol.TypeLoadModel, ModelID: "model-a"},
		},
		{
			name: "prefetch_model_default_priority", messageType: protocol.TypePrefetchModel,
			value: protocol.PrefetchModelMessage{Type: protocol.TypePrefetchModel, ModelID: "model-a"},
			notes: "Zero priority is omitted.",
		},
		{
			name: "prefetch_model_priority", messageType: protocol.TypePrefetchModel,
			value: protocol.PrefetchModelMessage{Type: protocol.TypePrefetchModel, ModelID: "model-a", Priority: 5},
		},
		{
			name: "desired_models", messageType: protocol.TypeDesiredModels,
			value: protocol.DesiredModelsMessage{
				Type: protocol.TypeDesiredModels,
				Models: []protocol.DesiredModelEntry{{
					ModelName: "public-a", DesiredBuild: "model-a", PreviousBuild: "model-old",
				}},
			},
		},
		{
			name: "trust_status", messageType: protocol.TypeTrustStatus,
			value: protocol.TrustStatusMessage{
				Type: protocol.TypeTrustStatus, TrustLevel: "hardware", Status: "online", Reason: "verified",
			},
		},
	}
	return marshalWireCases(values)
}

func marshalWireCases(values []struct {
	name        string
	messageType string
	value       any
	exact       bool
	notes       string
}) ([]wireCase, error) {
	cases := make([]wireCase, 0, len(values))
	for _, value := range values {
		wire, err := json.Marshal(value.value)
		if err != nil {
			return nil, fmt.Errorf("marshal protocol case %s: %w", value.name, err)
		}
		cases = append(cases, wireCase{
			Name: value.name, MessageType: value.messageType, Wire: string(wire),
			ExactBytes: value.exact, Notes: value.notes,
		})
	}
	return cases, nil
}

func renderProtocolInventory(providerCases, coordinatorCases []wireCase) string {
	var out strings.Builder
	out.WriteString("# Provider Protocol v1 Compatibility Inventory\n\n")
	out.WriteString("Generated by `make contracts-update`; do not edit by hand. Full field documentation lives in [`protocol-messages.md`](./protocol-messages.md).\n\n")
	out.WriteString("Protocol v1 uses JSON WebSocket text frames and has no explicit protocol negotiation. The Rust migration must decode every case below before any v1 traffic is accepted.\n\n")
	renderDirection := func(title string, cases []wireCase) {
		fmt.Fprintf(&out, "## %s\n\n", title)
		out.WriteString("| Type | Golden cases | Exact-byte requirement |\n|---|---|---|\n")
		byType := make(map[string][]wireCase)
		var order []string
		for _, contract := range cases {
			if _, exists := byType[contract.MessageType]; !exists {
				order = append(order, contract.MessageType)
			}
			byType[contract.MessageType] = append(byType[contract.MessageType], contract)
		}
		for _, messageType := range order {
			contracts := byType[messageType]
			names := make([]string, 0, len(contracts))
			exact := "semantic JSON"
			for _, contract := range contracts {
				names = append(names, "`"+contract.Name+"`")
				if contract.ExactBytes {
					exact = "preserve signed raw bytes"
				}
			}
			fmt.Fprintf(&out, "| `%s` | %s | %s |\n", messageType, strings.Join(names, ", "), exact)
		}
		out.WriteString("\n")
	}
	renderDirection("Provider → Coordinator", providerCases)
	renderDirection("Coordinator → Provider", coordinatorCases)
	out.WriteString("## Compatibility rules\n\n")
	out.WriteString("- Unknown additive JSON fields are tolerated; unknown message types are rejected.\n")
	out.WriteString("- Omitted, explicit `null`, zero, and `false` are distinct where the golden cases say so.\n")
	out.WriteString("- Signed registration attestation and status canonical payloads are byte contracts, not semantic JSON contracts.\n")
	out.WriteString("- Legacy `hypervisor_active=false` remains decodable because old provider signatures cover it.\n")
	out.WriteString("- `encrypted_response_chunks` means base64 ciphertext in v1 JSON; it must not be reinterpreted as protocol-v2 binary framing.\n")
	return out.String()
}

func float64Pointer(value float64) *float64 {
	return &value
}
