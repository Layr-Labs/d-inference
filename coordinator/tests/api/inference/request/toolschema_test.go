package request_test

import (
	"bytes"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api/inference/request"
)

// Swift: skipsNormalizationForOversizedBodies (+ at-cap boundary processed)
func TestNormalizeToolSchemas_SkipsNormalizationForOversizedBodies(t *testing.T) {
	// A body above the cap is returned unchanged BEFORE any parse, even though
	// it contains "tools" and a schema that WOULD be repaired — bounding the
	// JSON round-trip cost (DoS amplification).
	over := tsnPadBody(t, fixtureMaxToolNormalizationBytes+1)
	if out := production.NormalizeToolSchemas(over); !bytes.Equal(out, over) {
		t.Error("oversized body was modified")
	}
	// At exactly the cap the body is still normalized (the gate is strictly >).
	at := tsnPadBody(t, fixtureMaxToolNormalizationBytes)
	out := production.NormalizeToolSchemas(at)
	if bytes.Equal(out, at) {
		t.Fatal("at-cap body was not normalized")
	}
	u := tsnMap(t, tsnProps(t, out)["u"], "u")
	if got := tsnType(t, u, "u"); got != "string" {
		t.Errorf("u type = %q, want string", got)
	}
}
