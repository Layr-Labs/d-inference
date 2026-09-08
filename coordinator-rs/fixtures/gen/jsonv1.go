package main

import (
	"encoding/json"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// writeJSONV1Goldens marshals a representative populated instance and a
// zero-value instance (only Type set) of EVERY v1 message struct, pinning
// omitempty behavior, always-present fields, and null-vs-absent semantics.
func writeJSONV1Goldens(dir string) {
	f64 := func(v float64) *float64 { return &v }
	i := func(v int) *int { return &v }
	b := func(v bool) *bool { return &v }
	s := func(v string) *string { return &v }

	hardware := protocol.Hardware{
		MachineModel:       "Mac15,8",
		ChipName:           "Apple M3 Max",
		ChipFamily:         "M3",
		ChipTier:           "Max",
		MemoryGB:           128,
		MemoryAvailableGB:  88.5,
		CPUCores:           protocol.CPUCores{Total: 16, Performance: 12, Efficiency: 4},
		GPUCores:           40,
		MemoryBandwidthGBs: 409.6,
	}

	models := []protocol.ModelInfo{
		{
			ID:           "qwen-3-8b-4bit",
			SizeBytes:    4831838208,
			ModelType:    "text",
			Quantization: "4bit",
			WeightHash:   "0be6ff1c9e3a8d5f",
			IsVision:     false,
		},
		{
			ID:               "gemma-4-26b-8bit",
			SizeBytes:        27917287424,
			ModelType:        "text",
			Quantization:     "8bit",
			IsVision:         true,
			TemplateRenderOK: b(false), // explicit false must survive the wire
		},
	}

	// register ------------------------------------------------------------
	writeFile(dir, "register__populated.json", protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                hardware,
		Models:                  models,
		Backend:                 "mlx-swift",
		Version:                 "0.7.5",
		PublicKey:               "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
		EncryptedResponseChunks: true,
		Attestation:             json.RawMessage(signedAttestationJSON()),
		PrefillTPS:              512.25,
		DecodeTPS:               38.5,
		AuthToken:               "dbp_token_1234",
		PrivateOnly:             true,
		APNsDeviceToken:         "a1b2c3d4e5f6",
		APNsEnvironment:         "production",
		PythonHash:              "p-hash",
		RuntimeHash:             "r-hash",
		TemplateHashes:          map[string]string{"chatml": "aa11", "gemma": "bb22"},
		PrivacyCapabilities: &protocol.PrivacyCapabilities{
			TextBackendInprocess:    true,
			TextProxyDisabled:       true,
			PythonRuntimeLocked:     false,
			DangerousModulesBlocked: true,
			SIPEnabled:              true,
			AntiDebugEnabled:        false,
			CoreDumpsDisabled:       true,
			EnvScrubbed:             true,
		},
	})
	writeFile(dir, "register__zero.json", protocol.RegisterMessage{Type: protocol.TypeRegister})

	// heartbeat ------------------------------------------------------------
	writeFile(dir, "heartbeat__populated.json", protocol.HeartbeatMessage{
		Type:        protocol.TypeHeartbeat,
		Status:      "online",
		ActiveModel: s("qwen-3-8b-4bit"),
		Stats: protocol.HeartbeatStats{
			RequestsServed:               812,
			TokensGenerated:              913441,
			CancellationsReceived:        7,
			CancellationsBeforeOutput:    3,
			CancellationsPartialComplete: 4,
			GenerationErrorsAfterOutput:  1,
			ChunkEncryptionErrors:        0, // omitempty: must be absent
			StreamClosedWithoutTerminal:  2,
			CancelDuringModelLoad:        1,
			UsageGaps:                    1,
		},
		WarmModels: []string{"qwen-3-8b-4bit", "gemma-4-26b-8bit"},
		SystemMetrics: protocol.SystemMetrics{
			MemoryPressure: 0.35,
			CPUUsage:       0.62,
			ThermalState:   "nominal",
		},
		BackendCapacity: &protocol.BackendCapacity{
			Slots: []protocol.BackendSlotCapacity{
				{
					Model:                      "qwen-3-8b-4bit",
					State:                      "running",
					NumRunning:                 3,
					NumWaiting:                 1,
					MaxConcurrency:             8,
					ActiveTokens:               5210,
					MaxTokensPotential:         12288,
					ObservedDecodeTPS:          41.75,
					ObservedPrefillTPS:         633.5,
					ActiveTokenBudgetUsed:      9216,
					ActiveTokenBudgetMax:       65536,
					QueuedTokenBudget:          2048,
					KVBytesPerToken:            98304,
					ModelLoadTimeMS:            5400,
					StepsExecuted:              123456,
					Admits:                     900,
					FirstTokensEmitted:         890,
					SecondsSinceLastStep:       0.25,
					SecondsSinceLastFirstToken: 1.5,
					WedgeSuspected:             true,
					EvalInFlightMs:             120,
					IdleClearInFlightMs:        0, // omitempty: must be absent
				},
				{
					Model:              "gemma-4-26b-8bit",
					State:              "idle_shutdown",
					NumRunning:         0,
					NumWaiting:         0,
					ActiveTokens:       0,
					MaxTokensPotential: 0,
				},
			},
			GPUMemoryActiveGB: 41.5,
			GPUMemoryPeakGB:   55.25,
			GPUMemoryCacheGB:  6.125,
			TotalMemoryGB:     128,
			FreeForLoadGB:     f64(37.5),
		},
		APNsDeviceToken: "f6e5d4c3b2a1",
		APNsEnvironment: "development",
	})
	writeFile(dir, "heartbeat__zero.json", protocol.HeartbeatMessage{Type: protocol.TypeHeartbeat})

	// inference lifecycle (provider side) -----------------------------------
	writeFile(dir, "inference_accepted__populated.json", protocol.InferenceAcceptedMessage{
		Type:      protocol.TypeInferenceAccepted,
		RequestID: "req-42",
	})
	writeFile(dir, "inference_accepted__zero.json", protocol.InferenceAcceptedMessage{Type: protocol.TypeInferenceAccepted})

	writeFile(dir, "inference_response_chunk__plain.json", protocol.InferenceResponseChunkMessage{
		Type:      protocol.TypeInferenceResponseChunk,
		RequestID: "req-42",
		Data:      "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n",
	})
	writeFile(dir, "inference_response_chunk__encrypted.json", protocol.InferenceResponseChunkMessage{
		Type:      protocol.TypeInferenceResponseChunk,
		RequestID: "req-42",
		EncryptedData: &protocol.EncryptedPayload{
			EphemeralPublicKey: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
			Ciphertext:         "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAdGVzdA==",
		},
	})
	writeFile(dir, "inference_response_chunk__zero.json", protocol.InferenceResponseChunkMessage{Type: protocol.TypeInferenceResponseChunk})

	writeFile(dir, "inference_complete__populated.json", protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: "req-42",
		Usage: protocol.UsageInfo{
			PromptTokens:     128,
			CompletionTokens: 512,
			ReasoningTokens:  64,
		},
		SESignature:  "MEUCIQDexample==",
		ResponseHash: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
	})
	writeFile(dir, "inference_complete__zero.json", protocol.InferenceCompleteMessage{Type: protocol.TypeInferenceComplete})

	writeFile(dir, "inference_error__populated.json", protocol.InferenceErrorMessage{
		Type:        protocol.TypeInferenceError,
		RequestID:   "req-42",
		Error:       "backend crashed",
		StatusCode:  500,
		ErrorReason: protocol.ProviderDrainingForUpdate,
	})
	writeFile(dir, "inference_error__zero.json", protocol.InferenceErrorMessage{Type: protocol.TypeInferenceError})

	// attestation -----------------------------------------------------------
	writeFile(dir, "attestation_response__populated.json", protocol.AttestationResponseMessage{
		Type:              protocol.TypeAttestationResponse,
		Nonce:             "bm9uY2UtMzItYnl0ZXM=",
		Signature:         "MEYCIQDsig==",
		StatusSignature:   "MEYCIQDstatus==",
		PublicKey:         "BASE64PUBKEY=",
		HypervisorActive:  b(false), // legacy explicit false must survive
		RDMADisabled:      b(true),
		SIPEnabled:        b(true),
		SecureBootEnabled: b(true),
		BinaryHash:        "bh",
		ActiveModelHash:   "amh",
		PythonHash:        "ph",
		RuntimeHash:       "rh",
		TemplateHashes:    map[string]string{"chatml": "aa11"},
		ModelHashes:       map[string]string{"qwen-3-8b-4bit": "0be6ff1c9e3a8d5f"},
	})
	writeFile(dir, "attestation_response__zero.json", protocol.AttestationResponseMessage{Type: protocol.TypeAttestationResponse})

	writeFile(dir, "code_attestation_response__populated.json", protocol.CodeAttestationResponseMessage{
		Type:      protocol.TypeCodeAttestationResponse,
		Nonce:     "cHVzaGVkLW5vbmNl",
		Signature: "MEYCIQDcode==",
	})
	writeFile(dir, "code_attestation_response__zero.json", protocol.CodeAttestationResponseMessage{Type: protocol.TypeCodeAttestationResponse})

	// model lifecycle (provider side) ----------------------------------------
	writeFile(dir, "load_model_status__populated.json", protocol.LoadModelStatusMessage{
		Type:    protocol.TypeLoadModelStatus,
		ModelID: "qwen-3-8b-4bit",
		Status:  protocol.LoadModelStatusFailed,
		Error:   "GPU OOM",
	})
	writeFile(dir, "load_model_status__zero.json", protocol.LoadModelStatusMessage{Type: protocol.TypeLoadModelStatus})

	writeFile(dir, "prefetch_model_status__populated.json", protocol.PrefetchModelStatusMessage{
		Type:       protocol.TypePrefetchModelStatus,
		ModelID:    "gemma-4-26b-8bit",
		Status:     protocol.PrefetchModelStatusDownloading,
		BytesDone:  1073741824,
		BytesTotal: 27917287424,
	})
	writeFile(dir, "prefetch_model_status__zero.json", protocol.PrefetchModelStatusMessage{Type: protocol.TypePrefetchModelStatus})

	writeFile(dir, "models_update__populated.json", protocol.ModelsUpdateMessage{
		Type:   protocol.TypeModelsUpdate,
		Models: models,
	})
	writeFile(dir, "models_update__empty_slice.json", protocol.ModelsUpdateMessage{
		Type:   protocol.TypeModelsUpdate,
		Models: []protocol.ModelInfo{},
	})
	writeFile(dir, "models_update__zero.json", protocol.ModelsUpdateMessage{Type: protocol.TypeModelsUpdate})

	// coordinator → provider --------------------------------------------------
	writeFile(dir, "inference_request__plain.json", protocol.InferenceRequestMessage{
		Type:      protocol.TypeInferenceRequest,
		RequestID: "req-42",
		Body: protocol.InferenceRequestBody{
			Model: "qwen-3-8b-4bit",
			Messages: []protocol.ChatMessage{
				{Role: "system", Content: "You are helpful."},
				{Role: "user", Content: "こんにちは 🌍"},
			},
			Stream:      true,
			MaxTokens:   i(1024),
			Temperature: f64(0.7),
			Endpoint:    "/v1/chat/completions",
		},
	})
	writeFile(dir, "inference_request__encrypted.json", protocol.InferenceRequestMessage{
		Type:      protocol.TypeInferenceRequest,
		RequestID: "req-43",
		// Body stays zero-valued: Go's omitempty is a no-op on structs, so
		// the zero body is still on the wire. This variant pins that.
		EncryptedBody: &protocol.EncryptedPayload{
			EphemeralPublicKey: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
			Ciphertext:         "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAc2VjcmV0",
		},
	})
	writeFile(dir, "inference_request__zero.json", protocol.InferenceRequestMessage{Type: protocol.TypeInferenceRequest})

	writeFile(dir, "cancel__populated.json", protocol.CancelMessage{
		Type:      protocol.TypeCancel,
		RequestID: "req-42",
	})
	writeFile(dir, "cancel__zero.json", protocol.CancelMessage{Type: protocol.TypeCancel})

	writeFile(dir, "attestation_challenge__populated.json", protocol.AttestationChallengeMessage{
		Type:      protocol.TypeAttestationChallenge,
		Nonce:     "bm9uY2UtMzItYnl0ZXM=",
		Timestamp: "2026-07-09T12:34:56Z",
	})
	writeFile(dir, "attestation_challenge__zero.json", protocol.AttestationChallengeMessage{Type: protocol.TypeAttestationChallenge})

	writeFile(dir, "runtime_status__populated.json", protocol.RuntimeStatusMessage{
		Type:     protocol.TypeRuntimeStatus,
		Verified: false,
		Mismatches: []protocol.RuntimeMismatch{
			{Component: "runtime", Expected: "aa", Got: "bb"},
		},
	})
	writeFile(dir, "runtime_status__zero.json", protocol.RuntimeStatusMessage{Type: protocol.TypeRuntimeStatus})

	writeFile(dir, "load_model__populated.json", protocol.LoadModelMessage{
		Type:    protocol.TypeLoadModel,
		ModelID: "qwen-3-8b-4bit",
	})
	writeFile(dir, "load_model__zero.json", protocol.LoadModelMessage{Type: protocol.TypeLoadModel})

	writeFile(dir, "prefetch_model__populated.json", protocol.PrefetchModelMessage{
		Type:     protocol.TypePrefetchModel,
		ModelID:  "gemma-4-26b-8bit",
		Priority: 5,
	})
	writeFile(dir, "prefetch_model__zero.json", protocol.PrefetchModelMessage{Type: protocol.TypePrefetchModel})

	writeFile(dir, "desired_models__populated.json", protocol.DesiredModelsMessage{
		Type: protocol.TypeDesiredModels,
		Models: []protocol.DesiredModelEntry{
			{ModelName: "gemma-4-26b", DesiredBuild: "gemma-4-26b-8bit-r2", PreviousBuild: "gemma-4-26b-8bit"},
			{ModelName: "qwen-3-8b", DesiredBuild: "qwen-3-8b-4bit"},
		},
	})
	writeFile(dir, "desired_models__zero.json", protocol.DesiredModelsMessage{Type: protocol.TypeDesiredModels})

	writeFile(dir, "trust_status__populated.json", protocol.TrustStatusMessage{
		Type:       protocol.TypeTrustStatus,
		TrustLevel: "hardware",
		Status:     "online",
		Reason:     "mda_verified",
	})
	writeFile(dir, "trust_status__zero.json", protocol.TrustStatusMessage{Type: protocol.TypeTrustStatus})
}
