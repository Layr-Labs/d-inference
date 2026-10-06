package httpx_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
)

// decodeCappedJSON: over-cap (but valid-JSON-shaped) -> 413; small invalid JSON
// -> 400; valid -> ok with the value decoded.
func TestDecodeCappedJSON(t *testing.T) {
	const maxControlPlaneBodyBytes = 64 << 10
	type payload struct {
		X string `json:"x"`
	}

	t.Run("oversized->413", func(t *testing.T) {
		// Valid JSON shape that runs past the cap mid-string, so the decoder
		// hits the MaxBytesReader limit rather than a JSON syntax error.
		big := `{"x":"` + strings.Repeat("a", maxControlPlaneBodyBytes) + `"}`
		w := httptest.NewRecorder()
		r := httptest.NewRequest(http.MethodPost, "/x", strings.NewReader(big))
		var dst payload
		if httpx.DecodeCappedJSON(w, r, maxControlPlaneBodyBytes, &dst) {
			t.Fatal("expected ok=false for an over-cap body")
		}
		if w.Code != http.StatusRequestEntityTooLarge {
			t.Fatalf("oversized: got %d, want 413", w.Code)
		}
	})

	t.Run("invalidJSON->400", func(t *testing.T) {
		w := httptest.NewRecorder()
		r := httptest.NewRequest(http.MethodPost, "/x", strings.NewReader("not json"))
		var dst payload
		if httpx.DecodeCappedJSON(w, r, maxControlPlaneBodyBytes, &dst) {
			t.Fatal("expected ok=false for invalid JSON")
		}
		if w.Code != http.StatusBadRequest {
			t.Fatalf("invalid JSON: got %d, want 400", w.Code)
		}
	})

	t.Run("valid->ok", func(t *testing.T) {
		w := httptest.NewRecorder()
		r := httptest.NewRequest(http.MethodPost, "/x", strings.NewReader(`{"x":"hi"}`))
		var dst payload
		if !httpx.DecodeCappedJSON(w, r, maxControlPlaneBodyBytes, &dst) {
			t.Fatalf("expected ok=true for valid JSON (status %d)", w.Code)
		}
		if dst.X != "hi" {
			t.Fatalf("decoded X=%q, want %q", dst.X, "hi")
		}
	})
}
