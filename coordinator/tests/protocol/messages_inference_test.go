package protocol_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestInferenceResponseChunkMarshal(t *testing.T) {
	msg := production.InferenceResponseChunkMessage{
		Type:      production.TypeInferenceResponseChunk,
		RequestID: "req-123",
		Data:      "data: {\"id\":\"chatcmpl-xxx\",\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n",
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded production.InferenceResponseChunkMessage
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
	msg := production.InferenceCompleteMessage{
		Type:         production.TypeInferenceComplete,
		RequestID:    "req-456",
		Usage:        production.UsageInfo{PromptTokens: 50, CompletionTokens: 100},
		StopSequence: "<END>",
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded production.InferenceCompleteMessage
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
	msg := production.InferenceErrorMessage{
		Type:        production.TypeInferenceError,
		RequestID:   "req-789",
		Error:       "model not loaded",
		StatusCode:  500,
		ErrorReason: "model_load",
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded production.InferenceErrorMessage
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
	msg := production.InferenceRequestMessage{
		Type:          production.TypeInferenceRequest,
		RequestID:     "req-abc",
		EncryptedBody: &production.EncryptedPayload{EphemeralPublicKey: "ephemeral", Ciphertext: "sealed"},
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	// The request body travels only sealed; the frame has no plaintext body.
	var outer map[string]any
	if err := json.Unmarshal(data, &outer); err != nil {
		t.Fatal(err)
	}
	if _, plaintext := outer["body"]; plaintext {
		t.Fatalf("inference_request carries a plaintext body: %s", data)
	}

	var decoded production.InferenceRequestMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if decoded.RequestID != "req-abc" {
		t.Errorf("request_id = %q", decoded.RequestID)
	}
	if decoded.EncryptedBody == nil || decoded.EncryptedBody.Ciphertext != "sealed" || decoded.EncryptedBody.EphemeralPublicKey != "ephemeral" {
		t.Errorf("encrypted_body = %+v", decoded.EncryptedBody)
	}
}

func TestInferenceRequestFirstContentBudgetIsOptionalOuterAndCompatible(t *testing.T) {
	msg := production.InferenceRequestMessage{
		Type:                 production.TypeInferenceRequest,
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
	if _, plaintext := outer["body"]; plaintext {
		t.Fatalf("first_content_budget_ms frame grew a plaintext body: %s", data)
	}

	var decoded production.InferenceRequestMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.FirstContentBudgetMS != 2750 {
		t.Fatalf("FirstContentBudgetMS = %d, want 2750", decoded.FirstContentBudgetMS)
	}

	without, err := json.Marshal(production.InferenceRequestMessage{
		Type:      production.TypeInferenceRequest,
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
	var legacy production.InferenceRequestMessage
	if err := json.Unmarshal(legacyWithUnknown, &legacy); err != nil {
		t.Fatalf("legacy request with unknown field must decode: %v", err)
	}
	if legacy.RequestID != "legacy" || legacy.FirstContentBudgetMS != 0 {
		t.Fatalf("legacy request decoded incorrectly: %+v", legacy)
	}
}

// The first-sight depth is a bare integer beside the repeat count. It is left
// off the frame at 0, and a frame without it decodes to 0, which is how a
// provider that predates the field reads every request.
func TestInferenceRequestFirstSightTokensIsAnOptionalCount(t *testing.T) {
	repeat := 0
	msg := production.InferenceRequestMessage{Type: production.TypeInferenceRequest, RequestID: "req",
		CacheScope: "opaque-scope", CacheRepeatedPrefixTokens: &repeat, CacheFirstSightTokens: 4096}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}
	var outer map[string]any
	if err := json.Unmarshal(data, &outer); err != nil {
		t.Fatal(err)
	}
	if outer["cache_first_sight_tokens"] != float64(4096) || outer["cache_repeated_prefix_tokens"] != float64(0) {
		t.Fatalf("first-sight frame does not carry both counts as integers: %s", data)
	}
	var decoded production.InferenceRequestMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.CacheFirstSightTokens != 4096 || decoded.CacheRepeatedPrefixTokens == nil || *decoded.CacheRepeatedPrefixTokens != 0 {
		t.Fatalf("first-sight frame decoded incorrectly: %+v", decoded)
	}

	msg.CacheFirstSightTokens = 0
	without, err := json.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(without, []byte("cache_first_sight_tokens")) {
		t.Fatalf("zero first-sight count must be omitted: %s", without)
	}
	var repeated production.InferenceRequestMessage
	if err := json.Unmarshal([]byte(`{"type":"inference_request","request_id":"repeat","cache_scope":"s","cache_repeated_prefix_tokens":2048}`), &repeated); err != nil {
		t.Fatal(err)
	}
	if repeated.CacheFirstSightTokens != 0 || repeated.CacheRepeatedPrefixTokens == nil || *repeated.CacheRepeatedPrefixTokens != 2048 {
		t.Fatalf("frame without the field decoded incorrectly: %+v", repeated)
	}
}

func TestInferenceRequestCacheFieldsAreOptionalAndOuter(t *testing.T) {
	msg := production.InferenceRequestMessage{Type: production.TypeInferenceRequest, RequestID: "req"}
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
	without, err := json.Marshal(production.RegisterMessage{Type: production.TypeRegister})
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(without, []byte("prefix_cache_protocol")) {
		t.Fatalf("zero protocol version was not omitted: %s", without)
	}
	with, err := json.Marshal(production.RegisterMessage{Type: production.TypeRegister, PrefixCacheProtocol: 1})
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
		{`{"type":"prefix_cache_lookup","request_id":"r","cache_receipt_nonce":"n","outcome":"hit","tier":"ssd","cached_tokens":256,"prefill_tokens_saved":240,"stage_ms":3.5}`, &production.PrefixCacheLookupMessage{}},
		{`{"type":"prefix_cache_ready","request_id":"r","cache_receipt_nonce":"n","ready_tokens":512,"required_recompute_tokens":16,"expected_prefill_tokens_saved":496,"tier":"ssd","stage_ms":12.25}`, &production.PrefixCacheReadyMessage{}},
	} {
		var decoded production.ProviderMessage
		if err := json.Unmarshal([]byte(tc.wire), &decoded); err != nil {
			t.Fatalf("decode %s: %v", tc.wire, err)
		}
		switch tc.want.(type) {
		case *production.PrefixCacheLookupMessage:
			msg, ok := decoded.Payload.(*production.PrefixCacheLookupMessage)
			if !ok || msg.CacheReceiptNonce != "n" || msg.CachedTokens != 256 {
				t.Fatalf("lookup payload = %#v", decoded.Payload)
			}
		case *production.PrefixCacheReadyMessage:
			msg, ok := decoded.Payload.(*production.PrefixCacheReadyMessage)
			if !ok || msg.CacheReceiptNonce != "n" || msg.ReadyTokens != 512 || msg.StageMs != 12.25 {
				t.Fatalf("ready payload = %#v", decoded.Payload)
			}
		}
	}
}

func TestCancelMarshal(t *testing.T) {
	msg := production.CancelMessage{
		Type:      production.TypeCancel,
		RequestID: "req-cancel",
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded production.CancelMessage
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
		{"inference_complete", production.InferenceCompleteMessage{
			Type: production.TypeInferenceComplete, RequestID: "req-1",
			Usage: production.UsageInfo{PromptTokens: 10, CompletionTokens: 5}, Profile: profile,
		}, reflect.TypeOf(&production.InferenceCompleteMessage{})},
		{"inference_error", production.InferenceErrorMessage{
			Type: production.TypeInferenceError, RequestID: "req-2", Error: "x", StatusCode: 503,
			FailureCode: production.FailureCodeCapacity, Profile: profile,
		}, reflect.TypeOf(&production.InferenceErrorMessage{})},
	} {
		t.Run(tc.name, func(t *testing.T) {
			data, err := json.Marshal(tc.msg)
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			if !bytes.Contains(data, []byte(`"profile":{"schema":1,"total_us":3982400`)) {
				t.Fatalf("profile missing from wire: %s", data)
			}
			var pm production.ProviderMessage
			if err := pm.UnmarshalJSON(data); err != nil {
				t.Fatalf("UnmarshalJSON: %v", err)
			}
			if got := reflect.TypeOf(pm.Payload); got != tc.want {
				t.Fatalf("payload type = %v, want %v", got, tc.want)
			}
			var raw json.RawMessage
			switch p := pm.Payload.(type) {
			case *production.InferenceCompleteMessage:
				raw = p.Profile
			case *production.InferenceErrorMessage:
				raw = p.Profile
			}
			if !bytes.Equal(compactJSON(t, raw), compactJSON(t, profile)) {
				t.Fatalf("profile bytes changed in transit: %s", raw)
			}
			// The raw bytes are the typed decode target's input.
			var typed production.InferenceProfile
			if err := json.Unmarshal(raw, &typed); err != nil {
				t.Fatalf("typed decode: %v", err)
			}
			if typed.Schema == nil || *typed.Schema != 1 || typed.TotalUS == nil || *typed.TotalUS != 3982400 {
				t.Fatalf("typed profile = %+v", typed)
			}
			if typed.CancelStage != production.CancelStageNone || typed.Engine == nil || typed.Engine.FinishReason != production.EngineFinishStop {
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
			var pm production.ProviderMessage
			if err := pm.UnmarshalJSON([]byte(tc.in)); err != nil {
				t.Fatalf("UnmarshalJSON: %v", err)
			}
			switch p := pm.Payload.(type) {
			case *production.InferenceCompleteMessage:
				if p.Profile != nil {
					t.Fatalf("omitted profile decoded to %s, want nil", p.Profile)
				}
			case *production.InferenceErrorMessage:
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
		production.InferenceCompleteMessage{Type: production.TypeInferenceComplete, RequestID: "r"},
		production.InferenceErrorMessage{Type: production.TypeInferenceError, RequestID: "r", StatusCode: 500},
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
	var pm production.ProviderMessage
	if err := pm.UnmarshalJSON([]byte(in)); err != nil {
		t.Fatalf("envelope decode failed on a malformed profile: %v", err)
	}
	p, ok := pm.Payload.(*production.InferenceCompleteMessage)
	if !ok {
		t.Fatalf("payload %T", pm.Payload)
	}
	if p.Usage.CompletionTokens != 2 || string(p.Profile) != `{"schema":1,"total_us":"x"}` {
		t.Fatalf("payload = %+v", p)
	}
	var typed production.InferenceProfile
	if err := json.Unmarshal(p.Profile, &typed); err == nil {
		t.Fatal("typed decode accepted a string total_us")
	}
}

func TestDeadlineDecisionMalformedKeepsTerminalEnvelopeAlive(t *testing.T) {
	for _, terminal := range []string{
		`"type":"inference_complete","request_id":"r","usage":{"prompt_tokens":1,"completion_tokens":2}`,
		`"type":"inference_error","request_id":"r","error":"provider capacity unavailable","status_code":429`,
	} {
		for _, field := range []string{`"remaining_us":"bad"`, `"unbounded_reason":{"untrusted":"text"}`} {
			in := []byte(`{` + terminal + `,"profile":{"schema":1,"deadline_decision":{` + field + `}}}`)
			var pm production.ProviderMessage
			if err := pm.UnmarshalJSON(in); err != nil {
				t.Fatalf("diagnostic field cost the terminal: %v", err)
			}
			var raw json.RawMessage
			switch p := pm.Payload.(type) {
			case *production.InferenceCompleteMessage:
				raw = p.Profile
				if p.RequestID != "r" || p.Usage.CompletionTokens != 2 {
					t.Fatalf("completion changed: %+v", p)
				}
			case *production.InferenceErrorMessage:
				raw = p.Profile
				if p.RequestID != "r" || p.StatusCode != 429 {
					t.Fatalf("error changed: %+v", p)
				}
			default:
				t.Fatalf("unexpected terminal %T", pm.Payload)
			}
			var profile production.InferenceProfile
			if err := json.Unmarshal(raw, &profile); err == nil {
				t.Fatal("invalid nested diagnostic survived typed decode")
			}
		}
	}
}

// The oversize gate lives at ingress (registry.AttemptProfile.SetProviderProfileRaw)
// and in api.decodeInferenceProfile; the wire layer must still carry the frame
// so the terminal is never lost to a chatty profile.
func TestInferenceCompleteOversizeProfileStillDecodes(t *testing.T) {
	pad := bytes.Repeat([]byte("p"), production.MaxInferenceProfileBytes)
	in := `{"type":"inference_complete","request_id":"r","usage":{"prompt_tokens":1,"completion_tokens":2},"profile":{"schema":1,"padding":"` + string(pad) + `"}}`
	var pm production.ProviderMessage
	if err := pm.UnmarshalJSON([]byte(in)); err != nil {
		t.Fatalf("envelope decode: %v", err)
	}
	p := pm.Payload.(*production.InferenceCompleteMessage)
	if len(p.Profile) <= production.MaxInferenceProfileBytes {
		t.Fatalf("test profile is not oversize: %d bytes", len(p.Profile))
	}
}

// Every frame in the shared fixture decodes, the profiles fit the size cap,
// and the typed wire struct covers every key the fixture carries (no silent
// drops between the JSON contract and InferenceProfile).
func TestProfilerWireFixtureProfiles(t *testing.T) {
	frames := loadProfilerFixture(t)
	for name, wantKeys := range map[string]bool{
		"inference_complete_full":          true,
		"inference_complete_omitted":       false,
		"inference_error_minimal":          true,
		"inference_error_deadline":         true,
		"inference_error_accepted_expired": true,
		"inference_error_omitted":          false,
	} {
		t.Run(name, func(t *testing.T) {
			frame, ok := frames[name]
			if !ok {
				t.Fatalf("fixture frame %q missing", name)
			}
			var pm production.ProviderMessage
			if err := pm.UnmarshalJSON(frame); err != nil {
				t.Fatalf("UnmarshalJSON: %v", err)
			}
			var raw json.RawMessage
			switch p := pm.Payload.(type) {
			case *production.InferenceCompleteMessage:
				raw = p.Profile
			case *production.InferenceErrorMessage:
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
			if len(compact) > production.MaxInferenceProfileBytes {
				t.Fatalf("fixture profile is %d bytes, cap %d", len(compact), production.MaxInferenceProfileBytes)
			}
			var typed production.InferenceProfile
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
			if typed.Schema == nil || *typed.Schema != production.InferenceProfileSchema {
				t.Fatalf("schema = %v", typed.Schema)
			}
		})
	}
}
