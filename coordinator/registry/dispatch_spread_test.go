package registry

import (
	"fmt"
	"sort"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Dispatch replay: the CI anchor for the expected-completion cost term
// (completion_calibration.go, A5 §2.4 / P1). Only the TOKEN COUNT of the
// decode term changes (expected completion instead of max_tokens); the decode
// rate stays effectiveTPS, so the fixed queue/pending penalties remain the only
// contention pricing and the heterogeneous-fleet distribution at small
// max_tokens is byte-identical to before (pinned below).
//
// With max_tokens in the routing decode term, two boxes at 27 vs 26 tok/s
// differ by 16384/26 − 16384/27 ≈ 23 s of thisReqMs against an absolute 3 s
// near-tie window and a 3.75 s per-pending penalty, so inside one heartbeat
// gap the router fills the fastest tier to its concurrency cap before the next
// tier sees a request. The replay below drives the REAL scheduler
// (ReserveProviderEx) exactly the way the consumer does — sequential arrivals,
// no completions, no heartbeats — and measures the spread of the assignments
// as a Gini coefficient over per-provider load.

// spreadTestPublicKey is a valid base64 X25519 key (shared with the routingsim
// and api fixtures) so the private-text capability gate passes.
const spreadTestPublicKey = "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw="

type spreadTier struct {
	name   string
	tps    float64
	count  int
	memGB  int
	budget int64
	maxCon int
}

// registerSpreadProvider mirrors the production register + heartbeat state a
// routable Swift provider carries: hardware, static decode benchmark, a
// per-model slot with a concurrency cap, the observed decode EWMA and a
// non-binding token budget.
func registerSpreadProvider(reg *Registry, id, model string, t spreadTier) *Provider {
	msg := &protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel: "Mac15,8", ChipName: "Apple " + t.name, ChipFamily: "M3", ChipTier: "Max",
			MemoryGB: t.memGB, MemoryAvailableGB: float64(t.memGB), MemoryBandwidthGBs: 400,
			CPUCores: protocol.CPUCores{Total: 16, Performance: 12, Efficiency: 4}, GPUCores: 40,
		},
		Models:                  []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
		Backend:                 BackendMLXSwift,
		DecodeTPS:               t.tps,
		PublicKey:               spreadTestPublicKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities: &protocol.PrivacyCapabilities{
			TextBackendInprocess: true, TextProxyDisabled: true, PythonRuntimeLocked: true,
			DangerousModulesBlocked: true, SIPEnabled: true, AntiDebugEnabled: true,
			CoreDumpsDisabled: true, EnvScrubbed: true,
		},
	}
	p := reg.Register(id, nil, msg)
	p.mu.Lock()
	p.TrustLevel = TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.SystemMetrics = protocol.SystemMetrics{MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal"}
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: float64(t.memGB),
		Slots: []protocol.BackendSlotCapacity{{
			Model: model, State: "idle", NumRunning: 0, NumWaiting: 0,
			MaxConcurrency:       t.maxCon,
			ObservedDecodeTPS:    t.tps,
			ActiveTokenBudgetMax: t.budget,
		}},
	}
	p.mu.Unlock()
	reg.RecordChallengeSuccess(id)
	return p
}

// buildSpreadFleet registers every tier and returns provider ids plus an
// id → tier-name map.
func buildSpreadFleet(reg *Registry, model string, tiers []spreadTier) ([]string, map[string]string) {
	var ids []string
	tierOf := map[string]string{}
	for _, tier := range tiers {
		for j := 0; j < tier.count; j++ {
			id := fmt.Sprintf("%s-%03d", tier.name, j)
			registerSpreadProvider(reg, id, model, tier)
			ids = append(ids, id)
			tierOf[id] = tier.name
		}
	}
	return ids, tierOf
}

// homogeneousSpreadFleet is the A5 §2.4 replay fleet: 70 providers clustered
// 23..27 tok/s (14 per tier), per-slot MaxConcurrency 8, non-binding budgets.
func homogeneousSpreadFleet(reg *Registry, model string) []string {
	tiers := make([]spreadTier, 0, 5)
	for i, tps := range []float64{23, 24, 25, 26, 27} {
		tiers = append(tiers, spreadTier{name: fmt.Sprintf("T%d", i), tps: tps, count: 14, memGB: 64, budget: 400_000, maxCon: 8})
	}
	ids, _ := buildSpreadFleet(reg, model, tiers)
	return ids
}

// heterogeneousSpreadFleet is the A5 §2.4 mixed fleet: 40 × 14 tok/s (below
// the 15 tok/s decode-quality floor), 40 × 40 tok/s, 20 × 100 tok/s.
func heterogeneousSpreadFleet(reg *Registry, model string) ([]string, map[string]string) {
	return buildSpreadFleet(reg, model, []spreadTier{
		{name: "M1Pro", tps: 14, count: 40, memGB: 32, budget: 200_000, maxCon: 8},
		{name: "M2Max", tps: 40, count: 40, memGB: 64, budget: 400_000, maxCon: 8},
		{name: "M4Max", tps: 100, count: 20, memGB: 128, budget: 800_000, maxCon: 8},
	})
}

// spreadDecodeFloorTPS is the per-request decode-quality floor the replay
// carries (production: EIGENINFERENCE_MIN_DECODE_TPS=15, consumer.go sets
// PendingRequest.MinDecodeTPS). It is what keeps the 14 tok/s tier of the
// heterogeneous fleet idle: with the coordinator's in-gap pending charge
// (buildCandidateInto charges a reserved request's prompt + max_tokens to its
// box exactly as the box's next heartbeat will), a fast box holding a few
// in-gap pendings prices above an idle slow box, so only the soft quality
// preference — not cost — keeps the slow tier out, as in production.
const spreadDecodeFloorTPS = 15

// replayArrivals reserves arrivals sequentially with NO completions (one
// heartbeat gap) and returns per-provider load, the number of rejected
// arrivals, and the Gini coefficient of the load vector.
func replayArrivals(t *testing.T, reg *Registry, model string, ids []string, arrivals, prompt, maxTokens, expected int) (map[string]int, int, float64) {
	t.Helper()
	counts := make(map[string]int, len(ids))
	rejected := 0
	for i := 0; i < arrivals; i++ {
		pr := &PendingRequest{
			RequestID:                fmt.Sprintf("r%d", i),
			Model:                    model,
			EstimatedPromptTokens:    prompt,
			RequestedMaxTokens:       maxTokens,
			ExpectedCompletionTokens: expected,
			MinDecodeTPS:             spreadDecodeFloorTPS,
		}
		p, _ := reg.ReserveProviderEx(model, pr)
		if p == nil {
			rejected++
			continue
		}
		counts[p.ID]++
	}
	loads := make([]int, 0, len(ids))
	for _, id := range ids {
		loads = append(loads, counts[id])
	}
	return counts, rejected, giniCoefficient(loads)
}

// giniCoefficient of a non-negative load vector (0 = perfectly even).
func giniCoefficient(loads []int) float64 {
	x := append([]int(nil), loads...)
	sort.Ints(x)
	n := float64(len(x))
	if n == 0 {
		return 0
	}
	sum := 0.0
	acc := 0.0
	for i, v := range x {
		sum += float64(v)
		acc += float64(i+1) * float64(v)
	}
	if sum == 0 {
		return 0
	}
	return (2*acc)/(n*sum) - (n+1)/n
}

func maxLoad(counts map[string]int) int {
	m := 0
	for _, c := range counts {
		if c > m {
			m = c
		}
	}
	return m
}

func TestDispatchSpreadHomogeneousFleetAtLargeMaxTokens(t *testing.T) {
	const (
		model     = "spread-replay-model"
		arrivals  = 140
		prompt    = 1000
		maxTokens = 16384
	)

	t.Run("calibrated_expected_completion_spreads", func(t *testing.T) {
		t.Setenv("EIGENINFERENCE_COMPLETION_CALIBRATION", "on")
		reg := New(testLogger())
		ids := homogeneousSpreadFleet(reg, model)
		// Seed the completion calibrator past warm-up with p90 ≈ 500.
		seedCompletionWindow(reg, model, 50, 100, 500)
		expected, learned := reg.ExpectedCompletionTokensLearned(model, maxTokens)
		if !learned || expected < 400 || expected > 700 {
			t.Fatalf("seeded expected=%d learned=%v, want ~575/true", expected, learned)
		}

		counts, rejected, gini := replayArrivals(t, reg, model, ids, arrivals, prompt, maxTokens, expected)
		t.Logf("calibrated: rejected=%d providers_used=%d/%d max_load=%d gini=%.2f", rejected, len(counts), len(ids), maxLoad(counts), gini)
		if rejected != 0 {
			t.Fatalf("rejected=%d, want 0 (budgets are non-binding)", rejected)
		}
		if gini > 0.1 {
			t.Fatalf("gini=%.2f, want <= 0.1: the expected-completion decode term must restore the designed spread", gini)
		}
		if len(counts) != len(ids) {
			t.Fatalf("providers_used=%d, want all %d", len(counts), len(ids))
		}
	})

	t.Run("heterogeneous_fleet_keeps_slow_tier_idle", func(t *testing.T) {
		// Pins that ONLY the token count of the decode term changed: on the
		// mixed fleet the 14 tok/s tier (below the 15 tok/s quality floor) gets
		// zero dispatches and 60/100 providers serve, exactly as before the
		// calibration landed — at 256 (expected clamps to the bound, so the cost
		// is byte-identical) and at 16K (expected ≈ 575 replaces the bound).
		// A herd-projected decode RATE would have double-charged contention on
		// top of the fixed queue/pending penalties and pushed 40 arrivals onto
		// the slow tier at 256.
		t.Setenv("EIGENINFERENCE_COMPLETION_CALIBRATION", "on")
		for _, mt := range []int{256, 16384} {
			reg := New(testLogger())
			ids, tierOf := heterogeneousSpreadFleet(reg, model)
			seedCompletionWindow(reg, model, 50, 100, 500)
			expected := reg.ExpectedCompletionTokens(model, mt)
			counts, rejected, gini := replayArrivals(t, reg, model, ids, 200, prompt, mt, expected)
			tierCounts := map[string]int{}
			for id, c := range counts {
				tierCounts[tierOf[id]] += c
			}
			t.Logf("heterogeneous max_tokens=%d expected=%d: rejected=%d providers_used=%d/%d max_load=%d tiers=%v gini=%.2f",
				mt, expected, rejected, len(counts), len(ids), maxLoad(counts), tierCounts, gini)
			if rejected != 0 {
				t.Fatalf("max_tokens=%d: rejected=%d, want 0", mt, rejected)
			}
			if tierCounts["M1Pro"] != 0 {
				t.Fatalf("max_tokens=%d: the 14 tok/s tier received %d dispatches, want 0", mt, tierCounts["M1Pro"])
			}
			if len(counts) != 60 {
				t.Fatalf("max_tokens=%d: providers_used=%d, want 60 (the two fast tiers)", mt, len(counts))
			}
		}
	})

	t.Run("calibration_off_still_spreads_via_in_gap_charge", func(t *testing.T) {
		t.Setenv("EIGENINFERENCE_COMPLETION_CALIBRATION", "off")
		reg := New(testLogger())
		ids := homogeneousSpreadFleet(reg, model)
		seedCompletionWindow(reg, model, 50, 100, 500)
		// With the switch off the learned value is NOT applied: the consumer
		// passes the bound through, exactly as today.
		expected := reg.ExpectedCompletionTokens(model, maxTokens)
		if expected != maxTokens {
			t.Fatalf("switch off: expected=%d, want the bound %d", expected, maxTokens)
		}

		counts, rejected, gini := replayArrivals(t, reg, model, ids, arrivals, prompt, maxTokens, expected)
		t.Logf("uncalibrated: rejected=%d providers_used=%d/%d max_load=%d gini=%.2f", rejected, len(counts), len(ids), maxLoad(counts), gini)
		if rejected != 0 {
			t.Fatalf("rejected=%d, want 0", rejected)
		}
		// The pre-P1 failure mode (max_tokens/effectiveTPS dwarfing the tie
		// window, the fastest tier filling to its concurrency cap of 8 with a
		// Gini >= 0.5) no longer reproduces with the calibration off: the
		// coordinator's in-gap pending charge (buildCandidateInto) prices each
		// reserved request's prompt + max_tokens onto its box immediately, so a
		// box with one in-gap 16K pending costs more than an idle peer and the
		// cohort spreads on its own. The calibration and the in-gap charge are
		// complementary fixes for the same herd; with the switch off the
		// remaining spread comes from the charge alone.
		if gini > 0.1 {
			t.Fatalf("gini=%.2f, want <= 0.1: the in-gap pending charge must spread the cohort even with calibration off", gini)
		}
		if maxLoad(counts) > 2 {
			t.Fatalf("max_load=%d, want <= 2 (no box fills toward its cap of 8)", maxLoad(counts))
		}
	})
}
