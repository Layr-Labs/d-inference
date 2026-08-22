package protocol

import (
	"bytes"
	"encoding/json"
	"testing"
)

// TestModelInfoIsVisionSymmetry verifies the v0.6.0 is_vision field round-trips
// and is omitted when false, so a text-only build is wire-compatible with
// pre-0.6.0 providers (which never send it and decode it as false).
func TestModelInfoIsVisionSymmetry(t *testing.T) {
	// Vision build: is_vision present and true.
	vis := ModelInfo{ID: "gemma-4-26b-qat-4bit", SizeBytes: 1, IsVision: true}
	b, err := json.Marshal(vis)
	if err != nil {
		t.Fatalf("marshal vision: %v", err)
	}
	if !bytes.Contains(b, []byte(`"is_vision":true`)) {
		t.Fatalf("expected is_vision:true in JSON, got %s", b)
	}
	var back ModelInfo
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatalf("unmarshal vision: %v", err)
	}
	if !back.IsVision {
		t.Fatal("expected IsVision=true after round-trip")
	}

	// Text-only build: is_vision omitted entirely (omitempty), and a payload with
	// no is_vision key decodes to false.
	text := ModelInfo{ID: "gpt-oss-20b", SizeBytes: 1}
	b, err = json.Marshal(text)
	if err != nil {
		t.Fatalf("marshal text: %v", err)
	}
	if bytes.Contains(b, []byte("is_vision")) {
		t.Fatalf("expected is_vision to be omitted for a text-only build, got %s", b)
	}
	var legacy ModelInfo
	if err := json.Unmarshal([]byte(`{"id":"gpt-oss-20b","size_bytes":1}`), &legacy); err != nil {
		t.Fatalf("unmarshal legacy: %v", err)
	}
	if legacy.IsVision {
		t.Fatal("expected IsVision=false when the field is absent (pre-0.6.0 provider)")
	}
}
