package api

import "testing"

// TestEmitPrefillFallbackShadowWouldAdmit asserts the shadow counter is tagged
// would_admit when the recalibrated fallback clears the TTFT deadline a live
// (legacy) estimate sheds — the projected ttft_429 recovery the enforce flip buys.
func TestEmitPrefillFallbackShadowWouldAdmit(t *testing.T) {
	srv := newTTFTTestServer(t)
	srv.emitPrefillFallbackShadow("gpt-oss-20b", true, true)
	counters := srv.metrics.Snapshot().Counters
	if !counterMatches(counters, "routing.prefill_fallback", "decision=would_admit", "model=gpt-oss-20b", "mode=shadow") {
		t.Fatalf("missing routing.prefill_fallback{would_admit}; counters=%v", counters)
	}
}

// TestEmitPrefillFallbackShadowWouldShed covers the residual: even recalibrated,
// the request is over the deadline (enforce would not recover it).
func TestEmitPrefillFallbackShadowWouldShed(t *testing.T) {
	srv := newTTFTTestServer(t)
	srv.emitPrefillFallbackShadow("gpt-oss-20b", false, true)
	counters := srv.metrics.Snapshot().Counters
	if !counterMatches(counters, "routing.prefill_fallback", "decision=would_shed", "model=gpt-oss-20b", "mode=shadow") {
		t.Fatalf("missing routing.prefill_fallback{would_shed}; counters=%v", counters)
	}
}

// TestEmitPrefillFallbackShadowGateTag is the regression for the Codex finding:
// under the default SOFT gate a legacy ttft_too_slow is served anyway (no 429),
// so a would_admit there is a near-miss, not a recovered shed. The gate tag must
// distinguish the two so the recovery signal (gate:hard) is not inflated by
// already-served soft traffic. Fails without the gate tag (the pre-fix emitter
// tagged both identically).
func TestEmitPrefillFallbackShadowGateTag(t *testing.T) {
	srv := newTTFTTestServer(t)
	// Soft gate: a would_admit near-miss must carry gate=soft, NOT gate=hard.
	srv.emitPrefillFallbackShadow("gpt-oss-20b", true, false)
	counters := srv.metrics.Snapshot().Counters
	if !counterMatches(counters, "routing.prefill_fallback", "decision=would_admit", "gate=soft", "mode=shadow") {
		t.Fatalf("missing soft-gate near-miss tag routing.prefill_fallback{would_admit,gate=soft}; counters=%v", counters)
	}
	if counterMatches(counters, "routing.prefill_fallback", "decision=would_admit", "gate=hard") {
		t.Fatalf("soft-gate near-miss must not be counted as a hard-gate recovery; counters=%v", counters)
	}

	// Hard gate: the genuine projected ttft_429 recovery carries gate=hard.
	srv2 := newTTFTTestServer(t)
	srv2.emitPrefillFallbackShadow("gpt-oss-20b", true, true)
	counters2 := srv2.metrics.Snapshot().Counters
	if !counterMatches(counters2, "routing.prefill_fallback", "decision=would_admit", "gate=hard", "mode=shadow") {
		t.Fatalf("missing hard-gate recovery tag routing.prefill_fallback{would_admit,gate=hard}; counters=%v", counters2)
	}
}
