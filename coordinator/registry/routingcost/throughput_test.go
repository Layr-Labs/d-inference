package routingcost

import (
	"testing"
)

func TestResolveEffectiveTPSFallback(t *testing.T) {
	// When observedDecodeTPS is 0, should fall back to formula-based TPS.
	snap := routingSnapshot{
		DecodeTPS:         100,
		BackendRunning:    2,
		ObservedDecodeTPS: 0,
	}
	got := ResolveEffectiveTPS(snapPtr(snap))
	want := EffectiveDecodeTPS(100, 2)
	if got != want {
		t.Fatalf("resolveEffectiveTPS()=%f, want %f (formula fallback)", got, want)
	}

	// When observedDecodeTPS is set, should use it directly.
	snap.ObservedDecodeTPS = 55.5
	got = ResolveEffectiveTPS(snapPtr(snap))
	if got != 55.5 {
		t.Fatalf("resolveEffectiveTPS()=%f, want 55.5 (observed)", got)
	}
}
