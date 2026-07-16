package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestPrefixCacheV2CapabilityOmittedForLegacyRegistration(t *testing.T) {
	data, err := json.Marshal(RegisterMessage{
		Type:                TypeRegister,
		PrefixCacheProtocol: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "prefix_cache_v2_models") {
		t.Fatalf("legacy registration leaked v2 capabilities: %s", data)
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
