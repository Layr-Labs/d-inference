package protocol

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// TestTelemetryJSONSymmetry checks that the Go canonical encoding of a
// TelemetryEvent matches the Rust/TypeScript mirrors. Any change here must
// also be reflected in `provider/src/telemetry/event.rs` and
// `console-ui/src/lib/telemetry-types.ts` — those mirrors have their own
// symmetry tests that assert the same invariants.
func TestTelemetryJSONSymmetry(t *testing.T) {
	ev := TelemetryEvent{
		ID:        "00000000-0000-0000-0000-000000000001",
		Timestamp: time.Date(2026, 4, 16, 0, 0, 0, 0, time.UTC),
		Source:    TelemetrySourceProvider,
		Severity:  SeverityError,
		Kind:      KindBackendCrash,
		Version:   "0.3.10",
		SessionID: "abc",
		Message:   "hi",
	}
	raw, err := json.Marshal(ev)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	s := string(raw)

	// Enum serialization contract
	for _, want := range []string{
		`"source":"provider"`,
		`"severity":"error"`,
		`"kind":"backend_crash"`,
	} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %q in %s", want, s)
		}
	}

	// Optional-field omission contract (matches Rust skip_serializing_if)
	// NOTE: Go's `omitempty` is on all optional fields in our struct.
	for _, forbidden := range []string{
		`"machine_id":`,
		`"account_id":`,
		`"request_id":`,
		`"stack":`,
		`"fields":`,
	} {
		if strings.Contains(s, forbidden) {
			t.Errorf("optional %q should be omitted in %s", forbidden, s)
		}
	}
}

// TestTelemetryKindsMatch guards the protocol kind constants against
// accidental typos across layers.
func TestTelemetryKindsMatch(t *testing.T) {
	want := map[string]bool{
		"panic": true, "http_error": true, "protocol_error": true,
		"backend_crash": true, "attestation_failure": true,
		"inference_error": true, "runtime_mismatch": true,
		"connectivity": true, "log": true, "custom": true,
	}
	for k := range KnownKinds() {
		if !want[string(k)] {
			t.Errorf("unexpected kind %q", k)
		}
	}
	if len(KnownKinds()) != len(want) {
		t.Errorf("kind count mismatch: got %d want %d", len(KnownKinds()), len(want))
	}
}
