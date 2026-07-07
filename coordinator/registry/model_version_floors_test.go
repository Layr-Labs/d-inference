package registry

import (
	"testing"
	"time"
)

// floorProvider registers a routable provider advertising BOTH gemma and
// gpt-oss builds (a mixed box) running the given binary version.
func floorProvider(t *testing.T, reg *Registry, id, version string) *Provider {
	t.Helper()
	p := makeSchedulerProvider(t, reg, id, gemmaBuild, 30)
	addAdvertisedModel(p, gptossBuild)
	if version != "" {
		setProviderVersion(p, version)
	}
	return p
}

func TestParseModelVersionFloors(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want []ModelVersionFloor
	}{
		{"empty", "", nil},
		{"single", "gemma-4=0.7.5", []ModelVersionFloor{{Pattern: "gemma-4", Version: "0.7.5"}}},
		{"multi_with_spaces", " gemma-4 = 0.7.5 , gpt-oss = 0.8.0 ", []ModelVersionFloor{{Pattern: "gemma-4", Version: "0.7.5"}, {Pattern: "gpt-oss", Version: "0.8.0"}}},
		{"uppercase_pattern_lowered", "GEMMA-4=0.7.5", []ModelVersionFloor{{Pattern: "gemma-4", Version: "0.7.5"}}},
		// Malformed entries degrade to "no floor", never to a bad floor.
		{"bad_entries_skipped", "bogus,=0.7.5,gemma-4=,x", nil},
		{"mixed_valid_invalid", "bogus,gemma-4=0.7.5,=1", []ModelVersionFloor{{Pattern: "gemma-4", Version: "0.7.5"}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := ParseModelVersionFloors(tc.raw)
			if len(got) != len(tc.want) {
				t.Fatalf("ParseModelVersionFloors(%q) = %v, want %v", tc.raw, got, tc.want)
			}
			for i := range tc.want {
				if got[i] != tc.want[i] {
					t.Fatalf("ParseModelVersionFloors(%q)[%d] = %v, want %v", tc.raw, i, got[i], tc.want[i])
				}
			}
		})
	}
}

// TestModelVersionFloorRoutingGate is the migration regression: with
// gemma-4=0.7.5 configured, gemma routes ONLY to >=0.7.5 providers — a 0.7.4
// box and a version-less box advertising the same build are excluded — while
// gpt-oss (no floor) still routes to every box. Fails without the routing-gate
// check (all three boxes would serve gemma).
func TestModelVersionFloorRoutingGate(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelVersionFloors(ParseModelVersionFloors("gemma-4=0.7.5"))

	floorProvider(t, reg, "old-box", "0.7.4")
	floorProvider(t, reg, "no-version-box", "")

	// Below-floor and version-less boxes must not serve the floored model...
	if p := findRoutableProvider(reg, gemmaBuild); p != nil {
		t.Fatalf("gemma routed to %s, want no provider (both boxes below the 0.7.5 floor)", p.ID)
	}
	// ...but still serve unfloored models (only gemma is fenced).
	if p := findRoutableProvider(reg, gptossBuild); p == nil {
		t.Fatalf("gpt-oss unroutable — the floor must fence only matching models")
	}

	// A >=floor box serves the floored model; the substring match covers any
	// build id containing the pattern (same semantics as dedicated models).
	floorProvider(t, reg, "new-box", "0.7.5")
	p := findRoutableProvider(reg, gemmaBuild)
	if p == nil || p.ID != "new-box" {
		t.Fatalf("gemma routed to %v, want new-box (the only >=0.7.5 provider)", p)
	}
}

// TestModelVersionFloorPreflightConsistency: the capacity preflight
// (QuickCapacityCheck) funnels through the same routing gate, so a below-floor
// box is structurally absent there too — no phantom capacity that routing then
// refuses.
func TestModelVersionFloorPreflightConsistency(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelVersionFloors(ParseModelVersionFloors("gemma-4=0.7.5"))
	floorProvider(t, reg, "old-box", "0.7.4")

	candidates, capacityRejects, tooLarge := reg.QuickCapacityCheck(gemmaBuild, 500, 128, RequestTraits{})
	if candidates != 0 || capacityRejects != 0 || tooLarge != 0 {
		t.Fatalf("preflight for floored gemma = (%d, %d, %d), want (0, 0, 0): a below-floor box is structural absence, not capacity", candidates, capacityRejects, tooLarge)
	}
	if candidates, _, _ := reg.QuickCapacityCheck(gptossBuild, 500, 128, RequestTraits{}); candidates != 1 {
		t.Fatalf("preflight for unfloored gpt-oss = %d candidates, want 1", candidates)
	}
}

// TestModelVersionFloorDisabledByDefault pins the flag-off contract: with no
// floors configured (the default), below-floor and version-less providers
// route exactly as today.
func TestModelVersionFloorDisabledByDefault(t *testing.T) {
	reg := New(testLogger())
	floorProvider(t, reg, "old-box", "0.7.4")
	if p := findRoutableProvider(reg, gemmaBuild); p == nil {
		t.Fatalf("gemma unroutable with no floors configured — empty env must be zero behavior change")
	}

	// Setting then clearing the floors restores the default entirely.
	reg.SetModelVersionFloors(ParseModelVersionFloors("gemma-4=0.7.5"))
	if p := findRoutableProvider(reg, gemmaBuild); p != nil {
		t.Fatalf("floor set: gemma routed to %s, want none", p.ID)
	}
	reg.SetModelVersionFloors(nil)
	if p := findRoutableProvider(reg, gemmaBuild); p == nil {
		t.Fatalf("floors cleared: gemma unroutable, want routable again")
	}
}

// TestModelVersionFloorWarmPoolCandidacy: the warm-pool candidate gate applies
// the same floor with its own disqualification reason, so the controller never
// pre-warms a box routing won't use — and the reason tally exposes why.
func TestModelVersionFloorWarmPoolCandidacy(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelVersionFloors(ParseModelVersionFloors("gemma-4=0.7.5"))

	oldBox := floorProvider(t, reg, "old-box", "0.7.4")
	newBox := floorProvider(t, reg, "new-box", "0.7.5")
	// Make both boxes COLD for gemma (no gemma slot in backend capacity) so they
	// are warm-pool candidates rather than already-warm providers.
	for _, p := range []*Provider{oldBox, newBox} {
		p.mu.Lock()
		p.BackendCapacity.Slots = nil
		p.mu.Unlock()
	}

	now := time.Now()
	reg.mu.RLock()
	oldBox.mu.Lock()
	_, oldReason := reg.warmPoolCandidateReasonLocked(oldBox, gemmaBuild, now)
	oldBox.mu.Unlock()
	newBox.mu.Lock()
	_, newReason := reg.warmPoolCandidateReasonLocked(newBox, gemmaBuild, now)
	newBox.mu.Unlock()
	reg.mu.RUnlock()

	if oldReason != warmColdBelowVersionFloor {
		t.Fatalf("below-floor cold box reason = %q, want %q", oldReason, warmColdBelowVersionFloor)
	}
	if newReason != warmColdEligible {
		t.Fatalf(">=floor cold box reason = %q, want eligible", newReason)
	}

	// The fleet snapshot surfaces the tally under the exported reason string, so
	// "why is eligible_cold 0" is a dashboard, not a grep.
	snap := reg.warmPoolFleetSnapshot(now)[gemmaBuild]
	if len(snap.eligibleCold) != 1 || snap.eligibleCold[0].providerID != "new-box" {
		t.Fatalf("eligibleCold = %+v, want exactly new-box", snap.eligibleCold)
	}
	if snap.coldDisq[warmColdBelowVersionFloor] != 1 {
		t.Fatalf("coldDisq = %v, want %q: 1", snap.coldDisq, warmColdBelowVersionFloor)
	}
}
