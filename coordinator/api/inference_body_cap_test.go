package api

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
)

// Regression for the plaintext inference body cap: the path read the request
// body with an unbounded io.ReadAll, so any API-key holder could POST a multi-GB
// body and OOM the coordinator (the trusted TEE component). parseInferencePrelude
// now caps it with http.MaxBytesReader. These exercise the prelude directly — the
// size check returns before any auth/store access, so a zero-value Server
// suffices. (infiniteReader is shared from body_cap_test.go in this package.)

// Regression for the re-marshal inflation that the read cap alone didn't catch:
// the handlers re-marshal the parsed body before sealing it, and encoding/json's
// default HTML escaping turns each '<' '>' '&' into a 6-byte \uXXXX escape. A
// benign body that fit the read cap could thus re-marshal ~6× larger and produce
// a WebSocket frame the provider rejects (tearing down its session). The forward
// marshaler disables HTML escaping; this asserts the angle brackets survive raw
// and the output tracks the input size instead of exploding.
func TestMarshalForwardBodyDoesNotHTMLEscape(t *testing.T) {
	const n = 1 << 20 // 1 MiB of '<'
	body := map[string]any{
		"model":    "m",
		"messages": []any{map[string]any{"role": "user", "content": strings.Repeat("<", n)}},
	}

	got, err := inreq.MarshalForwardBody(body)
	if err != nil {
		t.Fatalf("marshalForwardBody: %v", err)
	}
	// The 6-byte JSON escape for '<' is the ASCII run \ u 0 0 3 c.
	escapedAngle := []byte{'\\', 'u', '0', '0', '3', 'c'}
	if bytes.Contains(got, escapedAngle) {
		t.Fatal(`marshalForwardBody HTML-escaped '<' to < — expected raw bytes`)
	}
	if !bytes.Contains(got, bytes.Repeat([]byte("<"), 8)) {
		t.Fatal("marshalForwardBody dropped the raw '<' run")
	}
	if got[len(got)-1] == '\n' {
		t.Fatal("marshalForwardBody left the encoder's trailing newline")
	}

	// The unescaped body must track the input (~1 MiB + small envelope); the
	// default escaping marshaler inflates the same body ~6×. Prove the gap.
	escaped, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	if len(escaped) <= len(got) {
		t.Fatalf("expected default Marshal (%d) larger than unescaped (%d)", len(escaped), len(got))
	}
	if len(got) > n+4096 {
		t.Fatalf("unescaped body unexpectedly large: %d bytes (input ~%d)", len(got), n)
	}
}
