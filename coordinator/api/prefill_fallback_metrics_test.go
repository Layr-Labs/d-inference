package api

import "testing"

// TestEmitPrefillFallbackShadowWouldAdmit asserts the shadow counter is tagged
// would_admit when the recalibrated fallback clears the TTFT deadline a live
// (legacy) estimate sheds — the projected ttft_429 recovery the enforce flip buys.
func TestEmitPrefillFallbackShadowWouldAdmit(t *testing.T) {
	srv := newTTFTTestServer(t)
	srv.emitPrefillFallbackShadow("gpt-oss-20b", true)
	counters := srv.metrics.Snapshot().Counters
	if !counterMatches(counters, "routing.prefill_fallback", "decision=would_admit", "model=gpt-oss-20b", "mode=shadow") {
		t.Fatalf("missing routing.prefill_fallback{would_admit}; counters=%v", counters)
	}
}

// TestEmitPrefillFallbackShadowWouldShed covers the residual: even recalibrated,
// the request is over the deadline (enforce would not recover it).
func TestEmitPrefillFallbackShadowWouldShed(t *testing.T) {
	srv := newTTFTTestServer(t)
	srv.emitPrefillFallbackShadow("gpt-oss-20b", false)
	counters := srv.metrics.Snapshot().Counters
	if !counterMatches(counters, "routing.prefill_fallback", "decision=would_shed", "model=gpt-oss-20b", "mode=shadow") {
		t.Fatalf("missing routing.prefill_fallback{would_shed}; counters=%v", counters)
	}
}
