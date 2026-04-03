package protocol

import (
	"encoding/json"
	"testing"
)

func BenchmarkMarshalRegisterMessage(b *testing.B) {
	b.ReportAllocs()
	msg := RegisterMessage{
		Type: TypeRegister,
		Hardware: Hardware{
			MachineModel:       "Mac15,8",
			ChipName:           "Apple M3 Max",
			ChipFamily:         "M3",
			ChipTier:           "Max",
			MemoryGB:           64,
			MemoryAvailableGB:  58.5,
			CPUCores:           CPUCores{Total: 16, Performance: 12, Efficiency: 4},
			GPUCores:           40,
			MemoryBandwidthGBs: 400,
		},
		Models: []ModelInfo{
			{ID: "mlx-community/Qwen3.5-9B-Instruct-4bit", SizeBytes: 5_700_000_000, ModelType: "qwen3", Quantization: "4bit"},
			{ID: "mlx-community/Trinity-Mini-8bit", SizeBytes: 14_200_000_000, ModelType: "qwen2_moe", Quantization: "8bit"},
		},
		Backend:       "vllm_mlx",
		PublicKey:     "dGVzdC1wdWJsaWMta2V5LWJhc2U2NC1lbmNvZGVk",
		WalletAddress: "0x1234567890abcdef1234567890abcdef12345678",
		PrefillTPS:    210.5,
		DecodeTPS:     55.3,
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = json.Marshal(msg)
	}
}

func BenchmarkUnmarshalProviderMessage(b *testing.B) {
	b.ReportAllocs()
	// Pre-serialize a heartbeat message (common provider->coordinator message).
	hb := HeartbeatMessage{
		Type:   TypeHeartbeat,
		Status: "idle",
		Stats: HeartbeatStats{
			RequestsServed:  1523,
			TokensGenerated: 4_892_310,
		},
		WarmModels: []string{
			"mlx-community/Qwen3.5-9B-Instruct-4bit",
			"mlx-community/Trinity-Mini-8bit",
		},
		SystemMetrics: SystemMetrics{
			MemoryPressure: 0.35,
			CPUUsage:       0.22,
			ThermalState:   "nominal",
		},
	}
	activeModel := "mlx-community/Qwen3.5-9B-Instruct-4bit"
	hb.ActiveModel = &activeModel

	data, _ := json.Marshal(hb)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		var pm ProviderMessage
		_ = pm.UnmarshalJSON(data)
	}
}

func BenchmarkMarshalInferenceRequest(b *testing.B) {
	b.ReportAllocs()
	msg := InferenceRequestMessage{
		Type:      TypeInferenceRequest,
		RequestID: "req-abc123-def456-789012",
		EncryptedBody: &EncryptedPayload{
			EphemeralPublicKey: "dGVzdC1lcGhlbWVyYWwtcHVibGljLWtleS0zMi1ieXRlcw==",
			Ciphertext:         "bm9uY2UtMjQtYnl0ZXMtaGVyZS4uLi5lbmNyeXB0ZWQtcGF5bG9hZC1kYXRhLXRoYXQtaXMtcXVpdGUtbG9uZy1mb3ItcmVhbGlzdGljLWJlbmNobWFyaw==",
		},
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, _ = json.Marshal(msg)
	}
}
