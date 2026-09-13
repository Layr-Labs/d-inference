package protocol

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

// TestCapacityProbeRoundTrip pins the probe's exact wire keys and its
// omission semantics: text-only probes omit the vision fields entirely so the
// frame a legacy-aware decoder sees stays minimal.
func TestCapacityProbeRoundTrip(t *testing.T) {
	probe := CapacityProbeMessage{
		Type:                TypeCapacityProbe,
		QuoteID:             "q-7f3a",
		Model:               "mlx-community/Qwen3.5-9B-Instruct-4bit",
		PromptTokensBucket:  1536,
		MaxOutputTokens:     2048,
		RequiresVision:      true,
		VisionImageCount:    3,
		DeadlineRemainingMS: 7250,
	}
	data, err := json.Marshal(probe)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var keys map[string]any
	if err := json.Unmarshal(data, &keys); err != nil {
		t.Fatalf("unmarshal to map: %v", err)
	}
	for _, want := range []string{
		"type", "quote_id", "model", "prompt_tokens_bucket",
		"max_output_tokens", "requires_vision", "vision_image_count",
		"deadline_remaining_ms",
	} {
		if _, ok := keys[want]; !ok {
			t.Errorf("key %q missing from wire frame: %s", want, data)
		}
	}

	var decoded CapacityProbeMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if decoded != probe {
		t.Errorf("round-trip mismatch: got %+v, want %+v", decoded, probe)
	}

	textOnly, err := json.Marshal(CapacityProbeMessage{
		Type:                TypeCapacityProbe,
		QuoteID:             "q-1",
		Model:               "m",
		PromptTokensBucket:  512,
		MaxOutputTokens:     256,
		DeadlineRemainingMS: 9000,
	})
	if err != nil {
		t.Fatalf("marshal text-only: %v", err)
	}
	for _, absent := range []string{"requires_vision", "vision_image_count"} {
		if strings.Contains(string(textOnly), absent) {
			t.Errorf("text-only probe must omit %q: %s", absent, textOnly)
		}
	}
}

// TestCapacityProbeShapeClosed is the privacy guard for the probe: probes
// reach providers that will never serve the request, so the field set is
// CLOSED to bucketed shape metadata. Adding any field here must be a
// deliberate act that updates this list — and it had better not carry prompt
// bytes, media, or identity.
func TestCapacityProbeShapeClosed(t *testing.T) {
	allowed := map[string]bool{
		"type":                  true,
		"quote_id":              true,
		"model":                 true,
		"prompt_tokens_bucket":  true,
		"max_output_tokens":     true,
		"requires_vision":       true,
		"vision_image_count":    true,
		"deadline_remaining_ms": true,
	}
	// Substrings that would indicate content or identity leaking into the
	// probe. quote_id is exempt by construction: it is random and
	// request-local, never the public request ID.
	forbidden := []string{
		"prompt_text", "body", "message", "content", "image_data",
		"ciphertext", "encrypted", "tool", "consumer", "account",
		"request_id", "session",
	}

	typ := reflect.TypeOf(CapacityProbeMessage{})
	for i := range typ.NumField() {
		tag := typ.Field(i).Tag.Get("json")
		name, _, _ := strings.Cut(tag, ",")
		if name == "" || name == "-" {
			t.Fatalf("field %s has no wire name; probe fields must be explicit", typ.Field(i).Name)
		}
		if !allowed[name] {
			t.Errorf("probe field %q is not in the closed privacy-reviewed set", name)
		}
		for _, bad := range forbidden {
			if strings.Contains(name, bad) {
				t.Errorf("probe field %q matches forbidden pattern %q", name, bad)
			}
		}
		delete(allowed, name)
	}
	for name := range allowed {
		t.Errorf("expected probe field %q is missing", name)
	}
}

// TestCapacityQuoteRoundTrip pins the quote's wire keys and the enum-omission
// rule: an admissible quote omits rejection_reason; a rejection carries a
// Valid() enum value.
func TestCapacityQuoteRoundTrip(t *testing.T) {
	admissible := CapacityQuoteMessage{
		Type:                 TypeCapacityQuote,
		QuoteID:              "q-7f3a",
		CapacitySeq:          42,
		AdmissibleNow:        true,
		TTFTP50MS:            310.5,
		TTFTP90MS:            980.25,
		QueueEstMS:           12.5,
		AvailableTokenBudget: 96000,
		Confidence:           CapacityConfidenceHigh,
	}
	data, err := json.Marshal(admissible)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(data), "rejection_reason") {
		t.Errorf("admissible quote must omit rejection_reason: %s", data)
	}
	for _, want := range []string{
		`"type":"capacity_quote"`, `"quote_id":"q-7f3a"`, `"capacity_seq":42`,
		`"admissible_now":true`, `"ttft_p50_ms":310.5`, `"ttft_p90_ms":980.25`,
		`"queue_est_ms":12.5`, `"available_token_budget":96000`, `"confidence":"high"`,
	} {
		if !strings.Contains(string(data), want) {
			t.Errorf("expected %s in wire frame: %s", want, data)
		}
	}
	var decoded CapacityQuoteMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if decoded != admissible {
		t.Errorf("round-trip mismatch: got %+v, want %+v", decoded, admissible)
	}

	rejected := admissible
	rejected.AdmissibleNow = false
	rejected.RejectionReason = RejectionReasonKVHeadroom
	rejected.AvailableTokenBudget = 0
	rejected.Confidence = CapacityConfidenceLow
	data, err = json.Marshal(rejected)
	if err != nil {
		t.Fatalf("marshal rejected: %v", err)
	}
	if !strings.Contains(string(data), `"rejection_reason":"kv_headroom"`) {
		t.Errorf("rejected quote must carry rejection_reason: %s", data)
	}
	var decodedRej CapacityQuoteMessage
	if err := json.Unmarshal(data, &decodedRej); err != nil {
		t.Fatalf("unmarshal rejected: %v", err)
	}
	if decodedRej != rejected {
		t.Errorf("rejected round-trip mismatch: got %+v, want %+v", decodedRej, rejected)
	}
	if !decodedRej.RejectionReason.Valid() {
		t.Errorf("decoded rejection reason %q should be Valid()", decodedRej.RejectionReason)
	}
}

// TestCapacityRejectionReasonValid pins the closed vocabulary in both
// directions: every published constant validates, everything else does not.
func TestCapacityRejectionReasonValid(t *testing.T) {
	for _, r := range []CapacityRejectionReason{
		RejectionReasonTokenBudget, RejectionReasonKVHeadroom,
		RejectionReasonMemoryCap, RejectionReasonSlotState,
		RejectionReasonTemplate, RejectionReasonCapability,
		RejectionReasonDeadline,
	} {
		if !r.Valid() {
			t.Errorf("%q should be valid", r)
		}
	}
	for _, r := range []CapacityRejectionReason{"", "oom", "TOKEN_BUDGET", "capacity"} {
		if r.Valid() {
			t.Errorf("%q should be invalid", r)
		}
	}
}

// TestProviderMessageUnmarshalCapacityQuote covers both decode paths of the
// envelope: the fast type-scan and the escape-forced envelope fallback must
// dispatch a capacity_quote frame to the same concrete payload.
func TestProviderMessageUnmarshalCapacityQuote(t *testing.T) {
	body := `"quote_id":"q-1","capacity_seq":7,"admissible_now":false,` +
		`"rejection_reason":"token_budget","ttft_p50_ms":400,"ttft_p90_ms":1200,` +
		`"queue_est_ms":80,"available_token_budget":1024,"confidence":"low"`
	frames := map[string]string{
		// \u0071 = 'q': the scanner bails on escapes and the envelope
		// fallback must reach the same dispatch.
		"fast-path": `{"type":"capacity_quote",` + body + `}`,
		"fallback":  `{"type":"capacity_\u0071uote",` + body + `}`,
	}
	for name, raw := range frames {
		t.Run(name, func(t *testing.T) {
			var pm ProviderMessage
			if err := json.Unmarshal([]byte(raw), &pm); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			if pm.Type != TypeCapacityQuote {
				t.Errorf("type = %q, want %q", pm.Type, TypeCapacityQuote)
			}
			quote, ok := pm.Payload.(*CapacityQuoteMessage)
			if !ok {
				t.Fatalf("payload type = %T, want *CapacityQuoteMessage", pm.Payload)
			}
			if quote.QuoteID != "q-1" || quote.CapacitySeq != 7 || quote.AdmissibleNow ||
				quote.RejectionReason != RejectionReasonTokenBudget ||
				quote.AvailableTokenBudget != 1024 || quote.Confidence != CapacityConfidenceLow {
				t.Errorf("quote payload = %+v", quote)
			}
		})
	}
}

// TestProviderMessageUnmarshalCapacityProbeRejected pins the envelope's
// directional invariant: capacity_probe is coordinator→provider, so — exactly
// like "cancel" or "inference_request" — a provider sending one must fail the
// envelope decode as an unknown type, not be accepted as a provider frame.
func TestProviderMessageUnmarshalCapacityProbeRejected(t *testing.T) {
	raw := `{"type":"capacity_probe","quote_id":"q-1","model":"m","prompt_tokens_bucket":512,"max_output_tokens":128,"deadline_remaining_ms":5000}`
	var pm ProviderMessage
	err := json.Unmarshal([]byte(raw), &pm)
	if err == nil {
		t.Fatalf("expected unknown-type error, got payload %T", pm.Payload)
	}
	if !strings.Contains(err.Error(), "unknown message type") {
		t.Errorf("error = %v, want unknown message type", err)
	}
}

// TestBackendCapacitySeqWire pins the heartbeat-level seq semantics: a legacy
// provider (seq 0) keeps the exact legacy wire shape, and a nonzero seq
// round-trips through the heartbeat envelope.
func TestBackendCapacitySeqWire(t *testing.T) {
	legacy, err := json.Marshal(BackendCapacity{TotalMemoryGB: 64})
	if err != nil {
		t.Fatalf("marshal legacy: %v", err)
	}
	if strings.Contains(string(legacy), "capacity_seq") {
		t.Errorf("zero capacity_seq must be omitted: %s", legacy)
	}

	raw := `{"type":"heartbeat","status":"idle","active_model":null,` +
		`"stats":{"requests_served":1,"tokens_generated":2},` +
		`"system_metrics":{"memory_pressure":0.1,"cpu_usage":0.2,"thermal_state":"nominal"},` +
		`"backend_capacity":{"slots":[],"gpu_memory_active_gb":1,"gpu_memory_peak_gb":2,` +
		`"gpu_memory_cache_gb":0.5,"total_memory_gb":64,"capacity_seq":9001}}`
	var pm ProviderMessage
	if err := json.Unmarshal([]byte(raw), &pm); err != nil {
		t.Fatalf("unmarshal heartbeat: %v", err)
	}
	hb, ok := pm.Payload.(*HeartbeatMessage)
	if !ok {
		t.Fatalf("payload type = %T, want *HeartbeatMessage", pm.Payload)
	}
	if hb.BackendCapacity == nil || hb.BackendCapacity.CapacitySeq != 9001 {
		t.Fatalf("capacity_seq = %+v, want 9001", hb.BackendCapacity)
	}
}

// TestInferenceErrorEnrichedRejectionWire pins the additive contract on
// inference_error: legacy frames without the routing-v2 fields decode to zero
// values (nil budget), a legacy-shaped struct marshals without the new keys,
// an enriched rejection round-trips all four fields, and — the P1-4 presence
// contract — an EXPLICIT zero live budget survives the wire instead of being
// conflated with "not enriched".
func TestInferenceErrorEnrichedRejectionWire(t *testing.T) {
	legacyRaw := `{"type":"inference_error","request_id":"req-1","error":"capacity","status_code":503,"failure_code":"capacity"}`
	var pm ProviderMessage
	if err := json.Unmarshal([]byte(legacyRaw), &pm); err != nil {
		t.Fatalf("unmarshal legacy: %v", err)
	}
	legacy, ok := pm.Payload.(*InferenceErrorMessage)
	if !ok {
		t.Fatalf("payload type = %T, want *InferenceErrorMessage", pm.Payload)
	}
	if legacy.RequestID != "req-1" || legacy.StatusCode != 503 || legacy.FailureCode != FailureCodeCapacity {
		t.Errorf("legacy fields disturbed: %+v", legacy)
	}
	if legacy.RejectionReason != "" || legacy.AvailableTokenBudget != nil ||
		legacy.FeasibleAfterMS != 0 || legacy.CapacitySeq != 0 {
		t.Errorf("legacy frame must decode with zero routing-v2 fields (nil budget): %+v", legacy)
	}
	reencoded, err := json.Marshal(legacy)
	if err != nil {
		t.Fatalf("marshal legacy: %v", err)
	}
	for _, absent := range []string{"rejection_reason", "available_token_budget", "feasible_after_ms", "capacity_seq"} {
		if strings.Contains(string(reencoded), absent) {
			t.Errorf("legacy-shaped struct must omit %q: %s", absent, reencoded)
		}
	}

	budget := int64(2048)
	enriched := InferenceErrorMessage{
		Type:                 TypeInferenceError,
		RequestID:            "req-2",
		Error:                "capacity",
		StatusCode:           503,
		FailureCode:          FailureCodeCapacity,
		RejectionReason:      RejectionReasonTokenBudget,
		AvailableTokenBudget: &budget,
		FeasibleAfterMS:      450,
		CapacitySeq:          17,
	}
	data, err := json.Marshal(enriched)
	if err != nil {
		t.Fatalf("marshal enriched: %v", err)
	}
	for _, want := range []string{
		`"rejection_reason":"token_budget"`, `"available_token_budget":2048`,
		`"feasible_after_ms":450`, `"capacity_seq":17`,
	} {
		if !strings.Contains(string(data), want) {
			t.Errorf("expected %s in enriched frame: %s", want, data)
		}
	}
	var decoded InferenceErrorMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal enriched: %v", err)
	}
	if !reflect.DeepEqual(decoded, enriched) {
		t.Errorf("enriched round-trip mismatch: got %+v, want %+v", decoded, enriched)
	}

	// Explicit zero: a busy slot with exactly zero tokens free is a real
	// measurement. It must be ENCODED (present key, value 0) and decode back
	// to a non-nil zero — never collapse to the legacy "absent" shape, which
	// would send the coordinator back to the stale heartbeat budget.
	zero := int64(0)
	zeroMsg := InferenceErrorMessage{
		Type:                 TypeInferenceError,
		RequestID:            "req-3",
		Error:                "capacity",
		StatusCode:           503,
		FailureCode:          FailureCodeCapacity,
		RejectionReason:      RejectionReasonTokenBudget,
		AvailableTokenBudget: &zero,
	}
	zeroData, err := json.Marshal(zeroMsg)
	if err != nil {
		t.Fatalf("marshal zero-budget: %v", err)
	}
	if !strings.Contains(string(zeroData), `"available_token_budget":0`) {
		t.Errorf("explicit zero budget must be encoded: %s", zeroData)
	}
	var zeroDecoded InferenceErrorMessage
	if err := json.Unmarshal(zeroData, &zeroDecoded); err != nil {
		t.Fatalf("unmarshal zero-budget: %v", err)
	}
	if zeroDecoded.AvailableTokenBudget == nil || *zeroDecoded.AvailableTokenBudget != 0 {
		t.Errorf("explicit zero budget must decode non-nil zero: %+v", zeroDecoded.AvailableTokenBudget)
	}
}
