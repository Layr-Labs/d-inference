package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestCheckpointCapabilityIsAdditiveInRegistrationAndHeartbeat(t *testing.T) {
	capability := PrefixCacheV2Capability{
		ModelID: "model", ModelAggregateHash: strings.Repeat("a", 64),
		PromptContractID: strings.Repeat("b", 64), BlockHashVersion: "dbk3", BlockSize: 256,
		CacheEpoch: "11111111-1111-1111-1111-111111111111", Enabled: true, Ready: true,
		ReadyBoundaryMode: PrefixCacheReadyBoundaryCheckpoint,
	}
	capabilities := []PrefixCacheV2Capability{capability}
	for _, frame := range []any{
		RegisterMessage{Type: TypeRegister, PrefixCacheProtocol: 2, PrefixCacheV2Models: capabilities},
		HeartbeatMessage{Type: TypeHeartbeat, PrefixCacheProtocol: 2, PrefixCacheV2Models: &capabilities},
	} {
		data, err := json.Marshal(frame)
		if err != nil {
			t.Fatal(err)
		}
		var message ProviderMessage
		if err := DecodeProviderMessage(data, &message); err != nil {
			t.Fatal(err)
		}
		var decoded []PrefixCacheV2Capability
		switch payload := message.Payload.(type) {
		case *RegisterMessage:
			decoded = payload.PrefixCacheV2Models
		case *HeartbeatMessage:
			decoded = *payload.PrefixCacheV2Models
		}
		if len(decoded) != 1 || decoded[0] != capability {
			t.Fatalf("checkpoint mode lost: %+v", decoded)
		}
		// Old coordinators decode ordinary JSON and ignore the additive key.
		// They cannot echo the mode, so new providers suppress these receipts.
		var legacy struct {
			Capabilities []struct {
				ModelID string `json:"model_id"`
				Enabled bool   `json:"enabled"`
				Ready   bool   `json:"ready"`
			} `json:"prefix_cache_v2_models"`
		}
		if err := json.Unmarshal(data, &legacy); err != nil {
			t.Fatal(err)
		}
		if len(legacy.Capabilities) != 1 || legacy.Capabilities[0].ModelID != "model" ||
			!legacy.Capabilities[0].Enabled || !legacy.Capabilities[0].Ready {
			t.Fatal("old capability decoding changed")
		}
	}
	capability.ReadyBoundaryMode = ""
	data, err := json.Marshal(capability)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "ready_boundary_mode") {
		t.Fatal("legacy capability grew a mode")
	}
	data, err = json.Marshal(InferenceRequestMessage{Type: TypeInferenceRequest})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "cache_receipt_boundary_mode") {
		t.Fatal("legacy request grew a negotiation echo")
	}
}

func TestPrefixCacheV2CapabilityOmittedForLegacyRegistration(t *testing.T) {
	data, err := json.Marshal(RegisterMessage{
		Type:                TypeRegister,
		PrefixCacheProtocol: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "prefix_cache_v2_models") || strings.Contains(string(data), "prefix_cache_memory_models") {
		t.Fatalf("legacy registration leaked v2 capabilities: %s", data)
	}
}

func TestPrefixCacheMemorySnapshotOmissionAndEmptyAreDistinct(t *testing.T) {
	for _, test := range []struct {
		body    string
		present bool
	}{
		{`{"type":"heartbeat","prefix_cache_protocol":2}`, false},
		{`{"type":"heartbeat","prefix_cache_protocol":2,"prefix_cache_memory_models":[]}`, true},
	} {
		var message ProviderMessage
		if err := json.Unmarshal([]byte(test.body), &message); err != nil {
			t.Fatal(err)
		}
		heartbeat := message.Payload.(*HeartbeatMessage)
		if (heartbeat.PrefixCacheMemoryModels != nil) != test.present {
			t.Fatalf("resident snapshot lost omission semantics: %+v", heartbeat)
		}
		if heartbeat.PrefixCacheV2Models != nil {
			t.Fatal("resident snapshot manufactured SSD inventory")
		}
		encoded, err := json.Marshal(heartbeat)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(encoded), "prefix_cache_memory_models") != test.present {
			t.Fatalf("roundtrip changed resident snapshot presence: %s", encoded)
		}
	}
}

func TestPrefixCacheV2MessagesDecodeDistinctPayloads(t *testing.T) {
	hash := strings.Repeat("a", 64)
	contract := strings.Repeat("b", 64)
	anchor := strings.Repeat("c", 64)
	for _, test := range []struct {
		name string
		body string
		want any
	}{
		{
			name: "lookup",
			body: `{"type":"prefix_cache_lookup_v2","request_id":"request","cache_receipt_nonce":"nonce",` +
				`"model_id":"model","model_aggregate_hash":"` + hash + `",` +
				`"prompt_contract_id":"` + contract + `","cache_epoch":"11111111-1111-1111-1111-111111111111",` +
				`"cache_seq":7,"prompt_anchor":{"chain_hash":"` + anchor + `","token_count":256},` +
				`"outcome":"miss_absent","tier":"ssd","stage_ms":1.5}`,
			want: &PrefixCacheLookupV2Message{},
		},
		{
			name: "ready",
			body: `{"type":"prefix_cache_ready_v2","request_id":"request","cache_receipt_nonce":"nonce",` +
				`"model_id":"model","model_aggregate_hash":"` + hash + `",` +
				`"prompt_contract_id":"` + contract + `","cache_epoch":"11111111-1111-1111-1111-111111111111",` +
				`"cache_seq":8,"outcome":"ready","tier":"ssd","ready_anchors":[{"chain_hash":"` +
				anchor + `","token_count":256}],"expected_prefill_tokens_saved":256,"stage_ms":2.5}`,
			want: &PrefixCacheReadyV2Message{},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			var message ProviderMessage
			if err := json.Unmarshal([]byte(test.body), &message); err != nil {
				t.Fatal(err)
			}
			switch test.want.(type) {
			case *PrefixCacheLookupV2Message:
				payload, ok := message.Payload.(*PrefixCacheLookupV2Message)
				if !ok || payload.CacheSeq != 7 || payload.PromptAnchor.TokenCount != 256 {
					t.Fatalf("unexpected lookup payload: %#v", message.Payload)
				}
			case *PrefixCacheReadyV2Message:
				payload, ok := message.Payload.(*PrefixCacheReadyV2Message)
				if !ok || payload.CacheSeq != 8 || len(payload.ReadyAnchors) != 1 {
					t.Fatalf("unexpected ready payload: %#v", message.Payload)
				}
			}
		})
	}
}
