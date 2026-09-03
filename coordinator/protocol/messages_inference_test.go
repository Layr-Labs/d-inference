package protocol

import (
	"bytes"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
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

func TestInferenceRequestFirstContentBudgetIsOptionalOuterAndCompatible(t *testing.T) {
	msg := InferenceRequestMessage{
		Type:                 TypeInferenceRequest,
		RequestID:            "req-budget",
		FirstContentBudgetMS: 2750,
	}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}
	var outer map[string]any
	if err := json.Unmarshal(data, &outer); err != nil {
		t.Fatal(err)
	}
	if got := outer["first_content_budget_ms"]; got != float64(2750) {
		t.Fatalf("first_content_budget_ms = %#v, want 2750", got)
	}
	body, ok := outer["body"].(map[string]any)
	if !ok {
		t.Fatalf("body = %#v, want JSON object", outer["body"])
	}
	if _, nested := body["first_content_budget_ms"]; nested {
		t.Fatalf("first_content_budget_ms must be outer wire metadata: %s", data)
	}

	var decoded InferenceRequestMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.FirstContentBudgetMS != 2750 {
		t.Fatalf("FirstContentBudgetMS = %d, want 2750", decoded.FirstContentBudgetMS)
	}

	without, err := json.Marshal(InferenceRequestMessage{
		Type:      TypeInferenceRequest,
		RequestID: "req-no-budget",
	})
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(without, []byte("first_content_budget_ms")) {
		t.Fatalf("zero budget must be omitted: %s", without)
	}

	legacyWithUnknown := []byte(
		`{"type":"inference_request","request_id":"legacy","body":{},"future_outer_field":{"enabled":true}}`,
	)
	var legacy InferenceRequestMessage
	if err := json.Unmarshal(legacyWithUnknown, &legacy); err != nil {
		t.Fatalf("legacy request with unknown field must decode: %v", err)
	}
	if legacy.RequestID != "legacy" || legacy.FirstContentBudgetMS != 0 {
		t.Fatalf("legacy request decoded incorrectly: %+v", legacy)
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

	msg.ToolSchemaMetadataProtocol = 1
	withMetadata, err := json.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(
		withMetadata,
		[]byte(`"tool_schema_metadata_protocol":1`),
	) {
		t.Fatalf("schema metadata protocol missing: %s", withMetadata)
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

// ---------------------------------------------------------------------------
// System profiler: `profile` on inference_complete / inference_error.
// Shared Go/Swift fixture: testdata/profiler_wire_fixture.json.
// ---------------------------------------------------------------------------

// loadProfilerFixture returns the fixture's top-level frames keyed by name.
func loadProfilerFixture(t *testing.T) map[string]json.RawMessage {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", "profiler_wire_fixture.json"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var frames map[string]json.RawMessage
	if err := json.Unmarshal(data, &frames); err != nil {
		t.Fatalf("fixture is not a JSON object: %v", err)
	}
	delete(frames, "_comment")
	return frames
}

// jsonKeySet returns every key in raw, recursively, as "a.b.c" paths.
func jsonKeySet(t *testing.T, raw []byte) map[string]bool {
	t.Helper()
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(raw, &obj); err != nil {
		t.Fatalf("not an object: %v", err)
	}
	keys := map[string]bool{}
	var walk func(prefix string, m map[string]json.RawMessage)
	walk = func(prefix string, m map[string]json.RawMessage) {
		for k, v := range m {
			keys[prefix+k] = true
			var nested map[string]json.RawMessage
			if len(v) > 0 && v[0] == '{' && json.Unmarshal(v, &nested) == nil {
				walk(prefix+k+".", nested)
			}
		}
	}
	walk("", obj)
	return keys
}

func compactJSON(t *testing.T, raw []byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	if err := json.Compact(&buf, raw); err != nil {
		t.Fatalf("compact: %v", err)
	}
	return buf.Bytes()
}

func TestInferenceCompleteProfileRoundTrip(t *testing.T) {
	profile := json.RawMessage(`{"schema":1,"total_us":3982400,"cancel_stage":"none","engine":{"finish_reason":"stop"}}`)
	for _, tc := range []struct {
		name string
		msg  any
		want reflect.Type
	}{
		{"inference_complete", InferenceCompleteMessage{
			Type: TypeInferenceComplete, RequestID: "req-1",
			Usage: UsageInfo{PromptTokens: 10, CompletionTokens: 5}, Profile: profile,
		}, reflect.TypeOf(&InferenceCompleteMessage{})},
		{"inference_error", InferenceErrorMessage{
			Type: TypeInferenceError, RequestID: "req-2", Error: "x", StatusCode: 503,
			FailureCode: FailureCodeCapacity, Profile: profile,
		}, reflect.TypeOf(&InferenceErrorMessage{})},
	} {
		t.Run(tc.name, func(t *testing.T) {
			data, err := json.Marshal(tc.msg)
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			if !bytes.Contains(data, []byte(`"profile":{"schema":1,"total_us":3982400`)) {
				t.Fatalf("profile missing from wire: %s", data)
			}
			var pm ProviderMessage
			if err := pm.UnmarshalJSON(data); err != nil {
				t.Fatalf("UnmarshalJSON: %v", err)
			}
			if got := reflect.TypeOf(pm.Payload); got != tc.want {
				t.Fatalf("payload type = %v, want %v", got, tc.want)
			}
			var raw json.RawMessage
			switch p := pm.Payload.(type) {
			case *InferenceCompleteMessage:
				raw = p.Profile
			case *InferenceErrorMessage:
				raw = p.Profile
			}
			if !bytes.Equal(compactJSON(t, raw), compactJSON(t, profile)) {
				t.Fatalf("profile bytes changed in transit: %s", raw)
			}
			// The raw bytes are the typed decode target's input.
			var typed InferenceProfile
			if err := json.Unmarshal(raw, &typed); err != nil {
				t.Fatalf("typed decode: %v", err)
			}
			if typed.Schema == nil || *typed.Schema != 1 || typed.TotalUS == nil || *typed.TotalUS != 3982400 {
				t.Fatalf("typed profile = %+v", typed)
			}
			if typed.CancelStage != CancelStageNone || typed.Engine == nil || typed.Engine.FinishReason != EngineFinishStop {
				t.Fatalf("typed enums = %q / %+v", typed.CancelStage, typed.Engine)
			}
		})
	}
}

func TestInferenceCompleteProfileOmittedCompatibility(t *testing.T) {
	// Exactly the pre-profiler terminal shapes.
	for _, tc := range []struct {
		name string
		in   string
	}{
		{"inference_complete", `{"type":"inference_complete","request_id":"r","usage":{"prompt_tokens":1,"completion_tokens":2}}`},
		{"inference_error", `{"type":"inference_error","request_id":"r","error":"x","status_code":503}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var pm ProviderMessage
			if err := pm.UnmarshalJSON([]byte(tc.in)); err != nil {
				t.Fatalf("UnmarshalJSON: %v", err)
			}
			switch p := pm.Payload.(type) {
			case *InferenceCompleteMessage:
				if p.Profile != nil {
					t.Fatalf("omitted profile decoded to %s, want nil", p.Profile)
				}
			case *InferenceErrorMessage:
				if p.Profile != nil {
					t.Fatalf("omitted profile decoded to %s, want nil", p.Profile)
				}
			default:
				t.Fatalf("payload %T", pm.Payload)
			}
		})
	}

	// Reverse direction: a message that never sets it keeps the prior wire
	// shape, so pre-profiler consumers see no new key.
	for _, msg := range []any{
		InferenceCompleteMessage{Type: TypeInferenceComplete, RequestID: "r"},
		InferenceErrorMessage{Type: TypeInferenceError, RequestID: "r", StatusCode: 500},
	} {
		data, err := json.Marshal(msg)
		if err != nil {
			t.Fatalf("marshal: %v", err)
		}
		if bytes.Contains(data, []byte("profile")) {
			t.Fatalf("nil Profile should be omitted, got %s", data)
		}
	}
}

// A malformed profile must never cost the terminal: the envelope decodes,
// the terminal is processed, and only the later typed decode fails.
func TestInferenceCompleteMalformedProfileKeepsEnvelopeAlive(t *testing.T) {
	in := `{"type":"inference_complete","request_id":"r","usage":{"prompt_tokens":1,"completion_tokens":2},"profile":{"schema":1,"total_us":"x"}}`
	var pm ProviderMessage
	if err := pm.UnmarshalJSON([]byte(in)); err != nil {
		t.Fatalf("envelope decode failed on a malformed profile: %v", err)
	}
	p, ok := pm.Payload.(*InferenceCompleteMessage)
	if !ok {
		t.Fatalf("payload %T", pm.Payload)
	}
	if p.Usage.CompletionTokens != 2 || string(p.Profile) != `{"schema":1,"total_us":"x"}` {
		t.Fatalf("payload = %+v", p)
	}
	var typed InferenceProfile
	if err := json.Unmarshal(p.Profile, &typed); err == nil {
		t.Fatal("typed decode accepted a string total_us")
	}
}

// The oversize gate lives at ingress (registry.AttemptProfile.SetProviderProfileRaw)
// and in api.decodeInferenceProfile; the wire layer must still carry the frame
// so the terminal is never lost to a chatty profile.
func TestInferenceCompleteOversizeProfileStillDecodes(t *testing.T) {
	pad := bytes.Repeat([]byte("p"), MaxInferenceProfileBytes)
	in := `{"type":"inference_complete","request_id":"r","usage":{"prompt_tokens":1,"completion_tokens":2},"profile":{"schema":1,"padding":"` + string(pad) + `"}}`
	var pm ProviderMessage
	if err := pm.UnmarshalJSON([]byte(in)); err != nil {
		t.Fatalf("envelope decode: %v", err)
	}
	p := pm.Payload.(*InferenceCompleteMessage)
	if len(p.Profile) <= MaxInferenceProfileBytes {
		t.Fatalf("test profile is not oversize: %d bytes", len(p.Profile))
	}
}

// Every frame in the shared fixture decodes, the profiles fit the size cap,
// and the typed wire struct covers every key the fixture carries (no silent
// drops between the JSON contract and InferenceProfile).
func TestProfilerWireFixtureProfiles(t *testing.T) {
	frames := loadProfilerFixture(t)
	for name, wantKeys := range map[string]bool{
		"inference_complete_full":    true,
		"inference_complete_omitted": false,
		"inference_error_minimal":    true,
		"inference_error_omitted":    false,
	} {
		t.Run(name, func(t *testing.T) {
			frame, ok := frames[name]
			if !ok {
				t.Fatalf("fixture frame %q missing", name)
			}
			var pm ProviderMessage
			if err := pm.UnmarshalJSON(frame); err != nil {
				t.Fatalf("UnmarshalJSON: %v", err)
			}
			var raw json.RawMessage
			switch p := pm.Payload.(type) {
			case *InferenceCompleteMessage:
				raw = p.Profile
			case *InferenceErrorMessage:
				raw = p.Profile
			default:
				t.Fatalf("payload %T", pm.Payload)
			}
			if !wantKeys {
				if raw != nil {
					t.Fatalf("omitted variant carried a profile: %s", raw)
				}
				return
			}
			compact := compactJSON(t, raw)
			if len(compact) > MaxInferenceProfileBytes {
				t.Fatalf("fixture profile is %d bytes, cap %d", len(compact), MaxInferenceProfileBytes)
			}
			var typed InferenceProfile
			if err := json.Unmarshal(compact, &typed); err != nil {
				t.Fatalf("typed decode: %v", err)
			}
			re, err := json.Marshal(typed)
			if err != nil {
				t.Fatalf("re-marshal: %v", err)
			}
			got, want := jsonKeySet(t, re), jsonKeySet(t, compact)
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("InferenceProfile key set differs from fixture:\n got %v\nwant %v", got, want)
			}
			if typed.Schema == nil || *typed.Schema != InferenceProfileSchema {
				t.Fatalf("schema = %v", typed.Schema)
			}
		})
	}
}
