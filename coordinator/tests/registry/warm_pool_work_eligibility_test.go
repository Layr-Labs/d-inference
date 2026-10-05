package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func heartbeatWarmWork(t *testing.T, r *production.Registry, p *production.Provider, tokens, count int64) {
	t.Helper()
	capacity := warmWorkCapacity("epoch", tokens, count, tokens/10, count)
	capacity.Slots[0].Model = p.Models[0].ID
	if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: capacity}) {
		t.Fatal("work heartbeat rejected")
	}
}

func TestWarmWorkRecoveryStartsNewBaseline(t *testing.T) {
	for _, tc := range []struct {
		name       string
		transition func(*testing.T, *production.Registry, *production.Provider)
	}{
		{"transient_untrust_between_frames", func(t *testing.T, r *production.Registry, p *production.Provider) {
			r.MarkUntrustedTransient(p.ID)
			if !r.RecordChallengeSuccess(p.ID) {
				t.Fatal("provider did not recover")
			}
		}},
		{"trust_floor_between_frames", func(_ *testing.T, r *production.Registry, p *production.Provider) {
			r.SetTrustLevel(p.ID, production.TrustSelfSigned)
			r.SetTrustLevel(p.ID, production.TrustHardware)
		}},
		{"attestation_between_frames", func(_ *testing.T, _ *production.Registry, p *production.Provider) {
			p.SetAttested(false, production.TrustSelfSigned)
			p.SetAttested(true, production.TrustHardware)
		}},
		{"catalog_between_frames", func(_ *testing.T, r *production.Registry, _ *production.Provider) {
			r.SetModelCatalog([]production.CatalogEntry{})
			r.SetModelCatalog([]production.CatalogEntry{{ID: "m"}})
		}},
		{"private_heartbeat_then_public", func(t *testing.T, r *production.Registry, p *production.Provider) {
			// PrivateOnly is immutable after registration in production; a
			// re-registration creates a new Provider. Exercise the heartbeat
			// gate explicitly too, without relying on reconnect cleanup.
			p.PrivateOnly = true
			heartbeatWarmWork(t, r, p, 1_000_000, 1)
			p.PrivateOnly = false
		}},
		{"untrusted_heartbeat_then_recovery", func(t *testing.T, r *production.Registry, p *production.Provider) {
			r.MarkUntrustedTransient(p.ID)
			heartbeatWarmWork(t, r, p, 1_000_000, 1)
			if !r.RecordChallengeSuccess(p.ID) {
				t.Fatal("provider did not recover")
			}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := newWarmRegistry(t)
			p := makeSchedulerProvider(t, r, "p", "m", 100)
			r.ConfigureWarmPool(testWarmPoolConfig())
			heartbeatWarmWork(t, r, p, 0, 0)
			tc.transition(t, r, p)
			heartbeatWarmWork(t, r, p, 8_000_000, 8)
			if len(warmFixtureFor(r).deps.State.Snapshot(time.Now(), time.Minute)) != 0 {
				t.Fatal("recovery replayed excluded work")
			}
			heartbeatWarmWork(t, r, p, 8_008_000, 16)
			b := warmFixtureFor(r).deps.State.Snapshot(time.Now(), time.Minute)["m"]
			if b.PromptWork.Count != 8 || b.PromptWork.Tokens != 1000 {
				t.Fatalf("fresh public work lost after recovery: %+v", b)
			}
		})
	}
}

func TestWarmWorkUnchangedCatalogAndFreshChallengePreserveBaseline(t *testing.T) {
	r := newWarmRegistry(t)
	r.SetModelCatalog([]production.CatalogEntry{{ID: "m"}})
	p := makeSchedulerProvider(t, r, "p", "m", 100)
	r.ConfigureWarmPool(testWarmPoolConfig())
	heartbeatWarmWork(t, r, p, 0, 0)
	r.SetModelCatalog([]production.CatalogEntry{{ID: "m"}})
	r.RecordChallengeSuccess(p.ID)
	r.ClearAppAttestServingAuthorization(p) // periodic no-op policy recheck
	heartbeatWarmWork(t, r, p, 8000, 8)
	if got := warmFixtureFor(r).deps.State.Snapshot(time.Now(), time.Minute)["m"].PromptWork.Count; got != 8 {
		t.Fatalf("unchanged policy discarded live baseline: samples=%d", got)
	}
}

func TestWarmWorkIneligibleReportsCannotLoadPublicFleet(t *testing.T) {
	for _, tc := range []struct {
		name    string
		exclude func(*production.Registry, *production.Provider)
	}{
		{"private", func(_ *production.Registry, p *production.Provider) { p.PrivateOnly = true }},
		{"untrusted", func(r *production.Registry, p *production.Provider) { r.MarkUntrustedTransient(p.ID) }},
		{"below_trust_floor", func(r *production.Registry, p *production.Provider) {
			r.SetTrustLevel(p.ID, production.TrustSelfSigned)
		}},
		{"runtime_unverified", func(_ *production.Registry, p *production.Provider) { p.RuntimeVerified = false }},
		{"stale_challenge", func(_ *production.Registry, p *production.Provider) {
			p.LastChallengeVerified = time.Now().Add(-32 * time.Minute)
		}},
		{"dedicated_pool_excluded", func(r *production.Registry, p *production.Provider) {
			p.Models = append(p.Models, protocol.ModelInfo{ID: "other"})
			r.SetDedicatedModels([]string{"m"})
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := newWarmRegistry(t)
			p := makeSchedulerProvider(t, r, "excluded", "m", 100)
			public := makeSchedulerProvider(t, r, "public", "m", 100)
			cold := makeWarmPoolColdProvider(t, r, "cold", "m", 100, 64, 8)
			cfg := testWarmPoolConfig()
			cfg.HeadroomEnabled = true
			r.ConfigureWarmPool(cfg)
			sent := captureWarmPoolLoads(r)
			// Start with an eligible baseline, then produce a large excluded
			// burst. Neither the first excluded frame nor subsequent deltas
			// may manufacture public demand.
			heartbeatWarmWork(t, r, p, 0, 0)
			tc.exclude(r, p)
			heartbeatWarmWork(t, r, p, 8_000_000, 8)
			heartbeatWarmWork(t, r, p, 16_000_000, 16)
			if warmFixtureFor(r).history(p.ID).Count() != 0 {
				t.Fatal("excluded report retained a recoverable baseline")
			}
			if len(warmFixtureFor(r).deps.State.Snapshot(time.Now(), time.Minute)) != 0 {
				t.Fatal("excluded work entered public demand buckets")
			}
			warmFixtureFor(r).runtime.Tick(time.Now().Add(2 * time.Second))
			if len(*sent) != 0 {
				t.Fatalf("excluded work drove public load: actions=%+v", *sent)
			}
			// Identical legitimate public work still drives the same cold
			// provider through the real controller/load_model action path.
			heartbeatWarmWork(t, r, public, 0, 0)
			heartbeatWarmWork(t, r, public, 8_000_000, 8)
			snaps := warmFixtureFor(r).runtime.Tick(time.Now().Add(2 * time.Second))
			if len(*sent) != 1 || (*sent)[0].ProviderID != cold.ID || (*sent)[0].ModelID != "m" {
				t.Fatalf("public work did not warm public fleet: actions=%+v snapshots=%+v", *sent, snaps)
			}
		})
	}
}

func TestWarmWorkAppAttestRenewalAndRecovery(t *testing.T) {
	for _, name := range []string{"fresh_renewal", "revoke_and_regrant", "expired_lease"} {
		loseAuthorization := name != "fresh_renewal"
		t.Run(name, func(t *testing.T) {
			r, p, lease := appAttestTestProvider(t, newWarmRegistry(t))
			r.ConfigureWarmPool(testWarmPoolConfig())
			if name == "expired_lease" {
				lease.ValidUntil = time.Now().Add(200 * time.Millisecond)
			}
			if !r.GrantAppAttestServingAuthorization(p, lease) {
				t.Fatal("initial lease rejected")
			}
			heartbeatWarmWork(t, r, p, 0, 0)
			if name == "revoke_and_regrant" {
				r.ClearAppAttestServingAuthorization(p)
			} else if name == "expired_lease" {
				time.Sleep(time.Until(lease.ValidUntil))
			} else {
				// App Attest kept authorization live while the independent
				// legacy challenge timestamp was absent.
				r.RecordChallengeSuccess(p.ID)
			}
			lease.IssuedAt = time.Now()
			lease.ValidUntil = lease.IssuedAt.Add(time.Minute)
			if !r.GrantAppAttestServingAuthorization(p, lease) {
				t.Fatal("renewal rejected")
			}
			heartbeatWarmWork(t, r, p, 8000, 8)
			got := warmFixtureFor(r).deps.State.Snapshot(time.Now(), time.Minute)[appAttestTestModel].PromptWork.Count
			want := int64(8)
			if loseAuthorization {
				want = 0
			}
			if got != want {
				t.Fatalf("samples after renewal = %d, want %d", got, want)
			}
			heartbeatWarmWork(t, r, p, 16000, 16)
			if got := warmFixtureFor(r).deps.State.Snapshot(time.Now(), time.Minute)[appAttestTestModel].PromptWork.Count; got != want+8 {
				t.Fatalf("fresh work after renewal = %d, want %d", got, want+8)
			}
		})
	}
}

func TestWarmWorkReleasePolicyActivationRebaselines(t *testing.T) {
	for _, mode := range []string{"optional_to_required", "shadow_to_enforced", "enforce_after", "scheduled_enforce_after"} {
		t.Run(mode, func(t *testing.T) {
			r := newWarmRegistry(t)
			p, evidence := grantRaceProvider(t, r, "p")
			p.Mu().Lock()
			testMakeTextRoutable(p)
			p.Mu().Unlock()
			r.ConfigureWarmPool(testWarmPoolConfig())
			var enforceAt time.Time
			switch mode {
			case "optional_to_required":
				r.SetReleasePolicyGeneration(1, false, nil)
				r.SetReleasePolicyEnforcement(true)
			case "shadow_to_enforced":
				r.SetReleasePolicyGeneration(1, true, nil)
			case "enforce_after", "scheduled_enforce_after":
				r.SetReleasePolicyGeneration(1, true, nil)
				enforceAt = time.Now().Add(time.Hour)
				if mode == "scheduled_enforce_after" {
					enforceAt = time.Now().Add(200 * time.Millisecond)
				}
				r.SetReleasePolicyEnforceAfter(enforceAt)
				r.SetReleasePolicyEnforcement(true)
			}
			heartbeatWarmWork(t, r, p, 0, 0)
			if warmFixtureFor(r).history(p.ID).Count() != 1 {
				t.Fatal("optional/shadow provider did not establish baseline")
			}
			switch mode {
			case "optional_to_required":
				r.SetReleasePolicyGeneration(1, true, nil)
			case "shadow_to_enforced":
				r.SetReleasePolicyEnforcement(true)
			case "enforce_after":
				r.SetReleasePolicyEnforceAfter(time.Now().Add(-time.Second))
			case "scheduled_enforce_after":
				// Let the actual deadline pass without invoking the setter's
				// invalidation path.
				time.Sleep(time.Until(enforceAt))
			}
			evidence.PolicyGeneration = 1
			if !p.GrantApplicationEvidenceIfNotUntrusted(evidence) {
				t.Fatal("current application evidence rejected")
			}
			r.RecordChallengeSuccess(p.ID)
			heartbeatWarmWork(t, r, p, 8000, 8)
			model := p.Models[0].ID
			if got := warmFixtureFor(r).deps.State.Snapshot(time.Now(), time.Minute)[model].PromptWork.Count; got != 0 {
				t.Fatalf("policy recovery replayed excluded work: samples=%d", got)
			}
			// A routine generation refresh carrying the same approved proof
			// forward preserves the recovered baseline.
			r.SetReleasePolicyGeneration(2, true, func(production.ApplicationEvidence) bool { return true })
			heartbeatWarmWork(t, r, p, 16000, 16)
			if got := warmFixtureFor(r).deps.State.Snapshot(time.Now(), time.Minute)[model].PromptWork.Count; got != 8 {
				t.Fatalf("approved policy refresh discarded fresh work: samples=%d", got)
			}
		})
	}
}
