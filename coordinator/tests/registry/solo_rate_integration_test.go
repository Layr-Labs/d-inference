package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// TestSoloClassKeyingEndToEndNoCrossTierOverCap drives the REAL heartbeat
// ingest so both the ingest key (heartbeat.go) and the resolver key
// (concurrency_cap.go) are exercised: two same-family boxes of different tiers
// (M4 Max fast, M4 Pro slow) serving gemma solo. With chip-CLASS keying the
// slow box's cap comes from its OWN 14 tok/s (→ cap 2) while the fast box keeps
// its wide cap from 40 tok/s. With family-only keying both tiers pool under
// "M4" and the slow box's cap inflates from the fast box's samples — the exact
// cross-tier over-admission this fix prevents. Reverting either the ingest or
// the resolver keying trips one of the two assertions.
func TestSoloClassKeyingEndToEndNoCrossTierOverCap(t *testing.T) {
	reg := newQualityRegistry(testLogger())
	enablePerModelQualityCap(t, reg, "", "", "5")

	mk := func(id, family, tier string) *production.Provider {
		p := qualityProvider(t, reg, id, gemmaBuild, 93)
		p.Mu().Lock()
		p.Hardware.ChipFamily = family
		p.Hardware.ChipTier = tier
		p.Mu().Unlock()
		return p
	}
	fast := mk("fast", "M4", "Max")
	slow := mk("slow", "M4", "Pro")

	// Five uncontended solo heartbeats each: fast decodes gemma at 40, slow at
	// 14. One running gemma request per heartbeat gates the sample in.
	for i := 0; i < 5; i++ {
		reg.Heartbeat("fast", soloHeartbeat([]protocol.BackendSlotCapacity{
			{Model: gemmaBuild, State: "running", NumRunning: 1, ObservedDecodeTPS: 40},
		}))
		reg.Heartbeat("slow", soloHeartbeat([]protocol.BackendSlotCapacity{
			{Model: gemmaBuild, State: "running", NumRunning: 1, ObservedDecodeTPS: 14},
		}))
	}

	if got := effCapResolved(reg, slow, gemmaBuild); got != 2 {
		t.Fatalf("slow (M4|Pro) gemma cap = %d, want 2 (its own 14 tok/s); family keying inflates it from the fast M4|Max box", got)
	}
	if got := effCapResolved(reg, fast, gemmaBuild); got <= 2 {
		t.Fatalf("fast (M4|Max) gemma cap = %d, want wide (its own 40 tok/s), not dragged down cross-tier", got)
	}
}

// TestSoloSeedFleetFallbacksParsing covers the clamp table directly, including
// the degenerate shapes parseModelFloatMap can hand it.
// --- Warm-pool consistency ---

// TestWarmPoolSnapshotDecodeSampleUsesSoloResolver: the warm-pool fleet
// snapshot's decode samples (→ soloDecodeTPS → warm-target quality
// concurrency) must come from the SAME solo resolver as the admission cap —
// here the gemma solo median (14) — not the collapsed under-load slot EWMA
// (2.6) and not the provider-level benchmark (93). Otherwise admission would
// cap a box at 2 while the warm-pool controller plans capacity as if it could
// take 19.
func TestWarmPoolSnapshotDecodeSampleUsesSoloResolver(t *testing.T) {
	reg := newQualityRegistry(testLogger())
	enablePerModelQualityCap(t, reg, "", "", "")
	p := qualityProvider(t, reg, "gemma-box", gemmaBuild, 93)
	p.Mu().Lock()
	p.BackendCapacity.Slots[0].ObservedDecodeTPS = 2.6 // collapsed contended EWMA
	p.Mu().Unlock()
	for i := 0; i < 5; i++ {
		reg.throughput.RecordSolo(gemmaBuild, "M3|Max", 14)
	}

	reg.ConfigureWarmPool(warmplan.Config{})
	snap := reg.fleet(time.Now())[gemmaBuild]
	if snap.SoloDecodeTPS != 14 {
		t.Fatalf("warm-pool soloDecodeTPS = %v, want 14 (solo median; EWMA 2.6 and benchmark 93 must not feed the warm target)", snap.SoloDecodeTPS)
	}
	if snap.ServiceDecodeTPS != 2.6 {
		t.Fatalf("warm-pool serviceDecodeTPS = %v, want observed 2.6 (E[S] keeps load-inclusive semantics)", snap.ServiceDecodeTPS)
	}
}
