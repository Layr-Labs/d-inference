package protocol

import (
	"bytes"
	"encoding/json"
	"net/http"
	"testing"
)

func TestInferenceResponseChunkMarshal(t *testing.T) {
	msg := InferenceResponseChunkMessage{
		Type:      TypeInferenceResponseChunk,
		RequestID: "req-123",
		Data:      "data: {\"id\":\"chatcmpl-xxx\",\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n",
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded InferenceResponseChunkMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.RequestID != "req-123" {
		t.Errorf("request_id = %q, want %q", decoded.RequestID, "req-123")
	}
	if decoded.Data == "" {
		t.Error("data is empty")
	}
}

func TestInferenceCompleteMarshal(t *testing.T) {
	msg := InferenceCompleteMessage{
		Type:         TypeInferenceComplete,
		RequestID:    "req-456",
		Usage:        UsageInfo{PromptTokens: 50, CompletionTokens: 100},
		StopSequence: "<END>",
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded InferenceCompleteMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.Usage.PromptTokens != 50 {
		t.Errorf("prompt_tokens = %d, want 50", decoded.Usage.PromptTokens)
	}
	if decoded.Usage.CompletionTokens != 100 {
		t.Errorf("completion_tokens = %d, want 100", decoded.Usage.CompletionTokens)
	}
	if decoded.StopSequence != "<END>" {
		t.Errorf("stop_sequence = %q, want <END>", decoded.StopSequence)
	}
}

func TestInferenceErrorMarshal(t *testing.T) {
	msg := InferenceErrorMessage{
		Type:        TypeInferenceError,
		RequestID:   "req-789",
		Error:       "model not loaded",
		StatusCode:  500,
		ErrorReason: "model_load",
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded InferenceErrorMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.Error != "model not loaded" {
		t.Errorf("error = %q", decoded.Error)
	}
	if decoded.StatusCode != http.StatusInternalServerError {
		t.Errorf("status_code = %d, want 500", decoded.StatusCode)
	}
	if decoded.ErrorReason != "model_load" {
		t.Errorf("error_reason = %q, want model_load", decoded.ErrorReason)
	}

	msg.ErrorReason = ""
	data, err = json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal without reason: %v", err)
	}
	if bytes.Contains(data, []byte("error_reason")) {
		t.Fatalf("error_reason should be omitted when empty, got %s", data)
	}
}

func TestInferenceRequestMarshal(t *testing.T) {
	msg := InferenceRequestMessage{
		Type:      TypeInferenceRequest,
		RequestID: "req-abc",
		Body: InferenceRequestBody{
			Model: "qwen3.5-9b",
			Messages: []ChatMessage{
				{Role: "user", Content: "hello"},
			},
			Stream: true,
		},
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded InferenceRequestMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.RequestID != "req-abc" {
		t.Errorf("request_id = %q", decoded.RequestID)
	}
	if decoded.Body.Model != "qwen3.5-9b" {
		t.Errorf("model = %q", decoded.Body.Model)
	}
	if !decoded.Body.Stream {
		t.Error("stream should be true")
	}
	if len(decoded.Body.Messages) != 1 || decoded.Body.Messages[0].Content != "hello" {
		t.Errorf("messages = %+v", decoded.Body.Messages)
	}
}

func TestInferenceRequestCacheFieldsAreOptionalAndOuter(t *testing.T) {
	msg := InferenceRequestMessage{Type: TypeInferenceRequest, RequestID: "req"}
	without, err := json.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(without, []byte("cache_scope")) || bytes.Contains(without, []byte("cache_receipt_nonce")) {
		t.Fatalf("zero-value cache fields were not omitted: %s", without)
	}
	msg.CacheReceiptNonce = "nonce"
	msg.CacheScope = "opaque-scope"
	with, err := json.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(with, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded["cache_receipt_nonce"] != "nonce" || decoded["cache_scope"] != "opaque-scope" {
		t.Fatalf("outer cache fields missing: %s", with)
	}
}

func TestRegisterPrefixCacheProtocolOptional(t *testing.T) {
	without, err := json.Marshal(RegisterMessage{Type: TypeRegister})
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(without, []byte("prefix_cache_protocol")) {
		t.Fatalf("zero protocol version was not omitted: %s", without)
	}
	with, err := json.Marshal(RegisterMessage{Type: TypeRegister, PrefixCacheProtocol: 1})
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(with, []byte(`"prefix_cache_protocol":1`)) {
		t.Fatalf("protocol version missing: %s", with)
	}
}

func TestPrefixCacheReceiptsDecode(t *testing.T) {
	for _, tc := range []struct {
		wire string
		want any
	}{
		{`{"type":"prefix_cache_lookup","request_id":"r","cache_receipt_nonce":"n","outcome":"hit","tier":"ssd","cached_tokens":256,"prefill_tokens_saved":240,"stage_ms":3.5}`, &PrefixCacheLookupMessage{}},
		{`{"type":"prefix_cache_ready","request_id":"r","cache_receipt_nonce":"n","ready_tokens":512,"required_recompute_tokens":16,"expected_prefill_tokens_saved":496,"tier":"ssd","stage_ms":12.25}`, &PrefixCacheReadyMessage{}},
	} {
		var decoded ProviderMessage
		if err := json.Unmarshal([]byte(tc.wire), &decoded); err != nil {
			t.Fatalf("decode %s: %v", tc.wire, err)
		}
		switch tc.want.(type) {
		case *PrefixCacheLookupMessage:
			msg, ok := decoded.Payload.(*PrefixCacheLookupMessage)
			if !ok || msg.CacheReceiptNonce != "n" || msg.CachedTokens != 256 {
				t.Fatalf("lookup payload = %#v", decoded.Payload)
			}
		case *PrefixCacheReadyMessage:
			msg, ok := decoded.Payload.(*PrefixCacheReadyMessage)
			if !ok || msg.CacheReceiptNonce != "n" || msg.ReadyTokens != 512 || msg.StageMs != 12.25 {
				t.Fatalf("ready payload = %#v", decoded.Payload)
			}
		}
	}
}

func TestCancelMarshal(t *testing.T) {
	msg := CancelMessage{
		Type:      TypeCancel,
		RequestID: "req-cancel",
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded CancelMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.RequestID != "req-cancel" {
		t.Errorf("request_id = %q", decoded.RequestID)
	}
}
