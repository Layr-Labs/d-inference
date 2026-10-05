package registry_test

import (
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

type commitModeFleet struct {
	*benchFleet
	checks *gateCharacterizationRegistry
	gates  *identitygate.Directory
}

// Apply the same six fault scripts to independently constructed commit modes.
func commitModeFleets(t *testing.T, model string) (map[string]*commitModeFleet, map[string]string) {
	t.Helper()
	fleets := map[string]*commitModeFleet{}
	for _, mode := range []string{"shared", "global"} {
		t.Setenv("EIGENINFERENCE_RESERVE_COMMIT_MODE", mode)
		options := identitygate.DefaultOptions()
		options.HealthEjectionEnabled = func() bool { return true }
		gates := identitygate.New(testLogger(), &options)
		checks := &gateCharacterizationRegistry{}
		f := buildBenchFleet(t, benchFleetProviders, benchFleetModels, production.Dependencies{
			IdentityGates: gates,
			Reservations: func(p *production.ReservationPlanner) production.ReservationPreparation {
				checks.eligibility = p
				return p
			},
			ModelLoadPlanning: func(p *production.ModelLoadPlanner) production.ModelLoadPlanning {
				checks.loads = p
				return p
			},
		})
		checks.Registry = f.reg
		fleets[mode] = &commitModeFleet{benchFleet: f, checks: checks, gates: gates}
	}
	ref := fleets["shared"]
	var budgeted, others []int
	for i := range ref.ids {
		if !benchProviderAdvertises(ref.benchFleet, i, model) {
			continue
		}
		if i%2 == 0 && ref.models[i%benchFleetModels] == model && len(budgeted) < 1 {
			budgeted = append(budgeted, i)
		} else {
			others = append(others, i)
		}
	}
	if len(budgeted) < 1 || len(others) < 8 {
		t.Fatalf("fixture too small: budgeted=%d others=%d", len(budgeted), len(others))
	}
	faulted := map[string]string{
		"breaker": ref.ids[others[0]], "ejected": ref.ids[others[1]],
		"capacity_cooldown": ref.ids[others[2]], "dispatch_load": ref.ids[others[3]],
		"error_cooldown": ref.ids[others[4]], "budget_clamp": ref.ids[budgeted[0]],
	}
	for _, f := range fleets {
		r := f.reg
		for i := 0; i < identitygate.ProviderBreakerConsecTrip; i++ {
			r.RecordProviderOutcome(faulted["breaker"], false, 500, "internal error")
		}
		ejectedP := r.GetProvider(faulted["ejected"])
		ejectedP.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: "SER-MODE-EJECT"})
		for i := 0; i < 8+1; i++ {
			r.RecordProviderServeOutcome("serial:SER-MODE-EJECT", false, 500, "boom")
		}
		for i := 0; i < identitygate.LoadCapacityCooldownConfig().Threshold+1; i++ {
			r.RecordCapacityReject(faulted["capacity_cooldown"], model)
		}
		r.RecordDispatchLoadFailure(faulted["dispatch_load"], model)
		for i := 0; i < 2; i++ {
			r.RecordInferenceError(faulted["error_cooldown"], model, 500, production.RequestTraits{HasTools: true}.CooldownShape())
		}
		r.RecordCapacityReject(faulted["budget_clamp"], model)
		if !r.ProviderBreakerOpen(faulted["breaker"]) || !r.HealthEjectionOpen("serial:SER-MODE-EJECT") ||
			!r.CapacityCooldownActive(faulted["capacity_cooldown"], model) ||
			!f.gates.ViewForSession(nil, faulted["dispatch_load"]).DispatchLoadCooled(model, time.Now()) ||
			!r.InferenceErrorCooldownActive(faulted["error_cooldown"], model, production.RequestTraits{HasTools: true}.CooldownShape()) ||
			!r.BudgetClampActive(faulted["budget_clamp"], model) {
			t.Fatal("precondition: every fault kind must be armed")
		}
	}
	return fleets, faulted
}

// Compare full routing and per-provider eligibility before and after concurrent
// scans, reservations and every per-request recorder on healthy advertisers.
func TestGateDecisionsIdenticalAcrossCommitModesUnderConcurrentRecorders(t *testing.T) {
	fleets, faulted := commitModeFleets(t, benchFleetModelID(0))
	model := benchFleetModelID(0)
	shapes := []struct {
		name   string
		traits production.RequestTraits
	}{
		{name: "plain"},
		{name: "tools", traits: production.RequestTraits{HasTools: true}},
	}
	compareWalks := func(stage string) {
		t.Helper()
		for _, shape := range shapes {
			var want walkOutcome
			for i, mode := range []string{"shared", "global"} {
				pr := benchPendingRequest(model, 0)
				pr.Traits = shape.traits
				f := fleets[mode]
				got := runWalks(f.reg, f.checks.eligibility, model, pr, shape.traits, false)
				if i == 0 {
					want = got
					continue
				}
				if !reflect.DeepEqual(got, want) {
					t.Fatalf("%s/%s: walks differ across commit modes\n shared: %+v\n global: %+v", stage, shape.name, want, got)
				}
			}
			for kind, id := range faulted {
				pr := benchPendingRequest(model, 0)
				pr.Traits = shape.traits
				f := fleets["shared"]
				got := runWalks(f.reg, f.checks.eligibility, model, pr, shape.traits, false)
				for _, poolID := range got.pool {
					if poolID == id && (kind != "error_cooldown" || shape.name == "tools") {
						t.Fatalf("%s/%s: %s provider %s is in the eligible pool", stage, shape.name, kind, id)
					}
				}
			}
		}
		now := time.Now()
		for kind, id := range faulted {
			var want gateOutcomes
			for i, mode := range []string{"shared", "global"} {
				f := fleets[mode]
				p := f.reg.GetProvider(id)
				got := collectGateOutcomes(f.checks, p, model, now)
				if i == 0 {
					want = got
					continue
				}
				if got != want {
					t.Fatalf("%s: %s provider gate outcomes differ across commit modes\n shared: %+v\n global: %+v", stage, kind, want, got)
				}
			}
		}
	}
	compareWalks("before")

	healthy := func(f *benchFleet) []string {
		var out []string
		for i, id := range f.ids {
			if !benchProviderAdvertises(f, i, model) {
				continue
			}
			isFaulted := false
			for _, fid := range faulted {
				if fid == id {
					isFaulted = true
				}
			}
			if !isFaulted {
				out = append(out, id)
			}
		}
		return out
	}
	for mode, f := range fleets {
		r := f.reg
		ids := healthy(f.benchFleet)
		const workers, iters = 8, 120
		var wg sync.WaitGroup
		for w := 0; w < workers; w++ {
			wg.Add(1)
			go func(w int) {
				defer wg.Done()
				for i := 0; i < iters; i++ {
					id := ids[(w*iters+i)%len(ids)]
					switch i % 7 {
					case 0:
						pr := benchPendingRequest(model, 100_000+w*iters+i)
						if p, _ := r.ReserveProviderEx(model, pr); p != nil {
							p.RemovePending(pr.RequestID)
						}
					case 1:
						r.QuickCapacityCheckForRequest(model, 600, 512, production.RequestTraits{HasTools: i%2 == 0}, false)
					case 2:
						r.RecordProviderOutcome(id, true, 200, "")
					case 3:
						r.RecordCapacityAccept(id, model)
					case 4:
						r.RecordInferenceSuccess(id, model, "base")
					case 5:
						if sid := r.GetProviderStableIdentity(id); sid != "" {
							r.RecordProviderServeOutcome(sid, true, 200, "")
						}
						r.ClearDispatchLoadCooldown(id, model)
					case 6:
						r.PredictServable(model, 600, 600, 512, 128_000, production.RequestTraits{}, false)
					}
				}
			}(w)
		}
		wg.Wait()
		if t.Failed() {
			t.Fatalf("%s: concurrent phase failed", mode)
		}
	}
	compareWalks("after")
}
