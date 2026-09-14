package dispatch

import (
	"bytes"
	"encoding/json"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// TestBodyForProviderPenaltyGating verifies the coordinator strips the penalty
// fields that crash the pre-fix VLM path, but ONLY for vision requests routed to
// a provider below penaltySafeProviderVersion. Fixed providers and text requests
// keep their penalties. See bodyForProvider.
func TestBodyForProviderPenaltyGating(t *testing.T) {
	visionBody := []byte(`{"model":"gemma-4-26b","temperature":1.0,"precision_probe":9007199254740993,"repetition_penalty":1.0,` +
		`"presence_penalty":0.0,"frequency_penalty":0.0,"messages":[{"role":"user","content":[` +
		`{"type":"text","text":"what is this?"},` +
		`{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}]}]}`)
	textBody := []byte(`{"model":"gemma-4-26b","repetition_penalty":1.3,` +
		`"messages":[{"role":"user","content":"hello"}]}`)

	has := func(body []byte, key string) bool {
		var m map[string]any
		if err := json.Unmarshal(body, &m); err != nil {
			t.Fatalf("unmarshal: %v", err)
		}
		_, ok := m[key]
		return ok
	}
	penalties := []string{"repetition_penalty", "presence_penalty", "frequency_penalty"}

	// Vision + pre-fix provider → penalties stripped, other fields kept.
	out := bodyForProvider(visionBody, true, &registry.Provider{Version: "0.6.6"})
	for _, k := range penalties {
		if has(out, k) {
			t.Fatalf("pre-fix vision provider: expected %q stripped", k)
		}
	}
	if !has(out, "temperature") || !has(out, "messages") {
		t.Fatal("pre-fix vision provider: non-penalty fields must be preserved")
	}
	if !bytes.Contains(out, []byte("9007199254740993")) {
		t.Fatalf("pre-fix vision provider: field stripping rounded an exact numeric literal: %s", out)
	}

	// Vision + provider with unknown version → stripped (conservative).
	if has(bodyForProvider(visionBody, true, &registry.Provider{Version: ""}), "repetition_penalty") {
		t.Fatal("unknown-version vision provider: expected penalties stripped")
	}

	// Vision + fixed provider (== and > floor) → penalties preserved.
	for _, v := range []string{"0.6.7", "0.7.0"} {
		if !has(bodyForProvider(visionBody, true, &registry.Provider{Version: v}), "repetition_penalty") {
			t.Fatalf("fixed provider %s: penalties must pass through", v)
		}
	}

	// Text request (any provider) → penalties preserved.
	if !has(bodyForProvider(textBody, false, &registry.Provider{Version: "0.6.6"}), "repetition_penalty") {
		t.Fatal("text request: penalties must pass through")
	}

	// Vision + pre-fix provider but no penalty fields → returns rawBody unchanged.
	clean := []byte(`{"model":"gemma-4-26b","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}]}]}`)
	if out := bodyForProvider(clean, true, &registry.Provider{Version: "0.6.6"}); string(out) != string(clean) {
		t.Fatal("no-penalty vision body should be returned unchanged")
	}
}
