package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func heartbeatWarmWork(t *testing.T, r *Registry, p *Provider, tokens, count int64) {
	t.Helper()
	capacity := warmWorkCapacity("epoch", tokens, count, tokens/10, count)
	capacity.Slots[0].Model = p.Models[0].ID
	if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: capacity}) {
		t.Fatal("work heartbeat rejected")
	}
}

func TestWarmWorkIneligibleReportsCannotLoadPublicFleet(t *testing.T) {
	for _, tc := range []struct {
		name    string
		exclude func(*Registry, *Provider)
	}{
		{"private", func(_ *Registry, p *Provider) { p.PrivateOnly = true }},
		{"untrusted", func(r *Registry, p *Provider) { r.MarkUntrustedTransient(p.ID) }},
		{"below_trust_floor", func(r *Registry, p *Provider) { r.SetTrustLevel(p.ID, TrustSelfSigned) }},
		{"runtime_unverified", func(_ *Registry, p *Provider) { p.RuntimeVerified = false }},
		{"stale_challenge", func(_ *Registry, p *Provider) {
			p.LastChallengeVerified = time.Now().Add(-2 * challengeFreshnessMaxAge)
		}},
		{"dedicated_pool_excluded", func(r *Registry, p *Provider) {
			p.Models = append(p.Models, protocol.ModelInfo{ID: "other"})
			r.SetDedicatedModels([]string{"m"})
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := New(testLogger())
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
			if len(p.warmWorkCounters) != 0 {
				t.Fatal("excluded report retained a recoverable baseline")
			}
			if len(r.warmPool.state.snapshot(time.Now(), time.Minute)) != 0 {
				t.Fatal("excluded work entered public demand buckets")
			}
			r.warmPool.tick(time.Now().Add(2 * time.Second))
			if len(*sent) != 0 {
				t.Fatalf("excluded work drove public load: actions=%+v", *sent)
			}
			// Identical legitimate public work still drives the same cold
			// provider through the real controller/load_model action path.
			heartbeatWarmWork(t, r, public, 0, 0)
			heartbeatWarmWork(t, r, public, 8_000_000, 8)
			snaps := r.warmPool.tick(time.Now().Add(2 * time.Second))
			if len(*sent) != 1 || (*sent)[0].providerID != cold.ID || (*sent)[0].modelID != "m" {
				t.Fatalf("public work did not warm public fleet: actions=%+v snapshots=%+v", *sent, snaps)
			}
		})
	}
}

func TestWarmWorkRecoveryStartsNewBaseline(t *testing.T) {
	for _, tc := range []struct {
		name       string
		transition func(*testing.T, *Registry, *Provider)
	}{
		{"transient_untrust_between_frames", func(t *testing.T, r *Registry, p *Provider) {
			r.MarkUntrustedTransient(p.ID)
			if !r.RecordChallengeSuccess(p.ID) {
				t.Fatal("provider did not recover")
			}
		}},
		{"trust_floor_between_frames", func(_ *testing.T, r *Registry, p *Provider) {
			r.SetTrustLevel(p.ID, TrustSelfSigned)
			r.SetTrustLevel(p.ID, TrustHardware)
		}},
		{"attestation_between_frames", func(_ *testing.T, _ *Registry, p *Provider) {
			p.SetAttested(false, TrustSelfSigned)
			p.SetAttested(true, TrustHardware)
		}},
		{"catalog_between_frames", func(_ *testing.T, r *Registry, _ *Provider) {
			r.SetModelCatalog([]CatalogEntry{})
			r.SetModelCatalog([]CatalogEntry{{ID: "m"}})
		}},
		{"private_heartbeat_then_public", func(t *testing.T, r *Registry, p *Provider) {
			// PrivateOnly is immutable after registration in production; a
			// re-registration creates a new Provider. Exercise the heartbeat
			// gate explicitly too, without relying on reconnect cleanup.
			p.PrivateOnly = true
			heartbeatWarmWork(t, r, p, 1_000_000, 1)
			p.PrivateOnly = false
		}},
		{"untrusted_heartbeat_then_recovery", func(t *testing.T, r *Registry, p *Provider) {
			r.MarkUntrustedTransient(p.ID)
			heartbeatWarmWork(t, r, p, 1_000_000, 1)
			if !r.RecordChallengeSuccess(p.ID) {
				t.Fatal("provider did not recover")
			}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := New(testLogger())
			p := makeSchedulerProvider(t, r, "p", "m", 100)
			r.ConfigureWarmPool(testWarmPoolConfig())
			heartbeatWarmWork(t, r, p, 0, 0)
			tc.transition(t, r, p)
			heartbeatWarmWork(t, r, p, 8_000_000, 8)
			if len(r.warmPool.state.snapshot(time.Now(), time.Minute)) != 0 {
				t.Fatal("recovery replayed excluded work")
			}
			heartbeatWarmWork(t, r, p, 8_008_000, 16)
			b := r.warmPool.state.snapshot(time.Now(), time.Minute)["m"]
			if b.promptWork.count != 8 || b.promptWork.tokens != 1000 {
				t.Fatalf("fresh public work lost after recovery: %+v", b)
			}
		})
	}
}

func TestWarmWorkUnchangedCatalogAndFreshChallengePreserveBaseline(t *testing.T) {
	r := New(testLogger())
	r.SetModelCatalog([]CatalogEntry{{ID: "m"}})
	p := makeSchedulerProvider(t, r, "p", "m", 100)
	r.ConfigureWarmPool(testWarmPoolConfig())
	heartbeatWarmWork(t, r, p, 0, 0)
	r.SetModelCatalog([]CatalogEntry{{ID: "m"}})
	r.RecordChallengeSuccess(p.ID)
	r.ClearAppAttestServingAuthorization(p) // periodic no-op policy recheck
	heartbeatWarmWork(t, r, p, 8000, 8)
	if got := r.warmPool.state.snapshot(time.Now(), time.Minute)["m"].promptWork.count; got != 8 {
		t.Fatalf("unchanged policy discarded live baseline: samples=%d", got)
	}
}

func TestWarmWorkAppAttestRenewalAndRecovery(t *testing.T) {
	for _, name := range []string{"fresh_renewal", "revoke_and_regrant", "expired_lease"} {
		loseAuthorization := name != "fresh_renewal"
		t.Run(name, func(t *testing.T) {
			r, p, lease := appAttestTestProvider(t)
			r.ConfigureWarmPool(testWarmPoolConfig())
			if !r.GrantAppAttestServingAuthorization(p, lease) {
				t.Fatal("initial lease rejected")
			}
			heartbeatWarmWork(t, r, p, 0, 0)
			if name == "revoke_and_regrant" {
				r.ClearAppAttestServingAuthorization(p)
			} else if name == "expired_lease" {
				p.mu.Lock()
				p.appAttestAuthorization.ValidUntil = time.Now().Add(-time.Second)
				p.mu.Unlock()
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
			got := r.warmPool.state.snapshot(time.Now(), time.Minute)[appAttestTestModel].promptWork.count
			want := int64(8)
			if loseAuthorization {
				want = 0
			}
			if got != want {
				t.Fatalf("samples after renewal = %d, want %d", got, want)
			}
			heartbeatWarmWork(t, r, p, 16000, 16)
			if got := r.warmPool.state.snapshot(time.Now(), time.Minute)[appAttestTestModel].promptWork.count; got != want+8 {
				t.Fatalf("fresh work after renewal = %d, want %d", got, want+8)
			}
		})
	}
}

func TestWarmWorkReleasePolicyActivationRebaselines(t *testing.T) {
	for _, mode := range []string{"optional_to_required", "shadow_to_enforced", "enforce_after", "scheduled_enforce_after"} {
		t.Run(mode, func(t *testing.T) {
			r := New(testLogger())
			p, evidence := grantRaceProvider(t, r, "p")
			p.mu.Lock()
			testMakeTextRoutable(p)
			p.mu.Unlock()
			r.ConfigureWarmPool(testWarmPoolConfig())
			switch mode {
			case "optional_to_required":
				r.SetReleasePolicyGeneration(1, false, nil)
				r.SetReleasePolicyEnforcement(true)
			case "shadow_to_enforced":
				r.SetReleasePolicyGeneration(1, true, nil)
			case "enforce_after", "scheduled_enforce_after":
				r.SetReleasePolicyGeneration(1, true, nil)
				r.SetReleasePolicyEnforceAfter(time.Now().Add(time.Hour))
				r.SetReleasePolicyEnforcement(true)
			}
			heartbeatWarmWork(t, r, p, 0, 0)
			if len(p.warmWorkCounters) != 1 {
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
				// Simulate the clock passing the scheduled deadline, without
				// invoking the policy setter's invalidation hook.
				r.mu.Lock()
				r.releasePolicyEnforceAfter = time.Now().Add(-time.Second)
				r.mu.Unlock()
			}
			evidence.PolicyGeneration = 1
			if !p.GrantApplicationEvidenceIfNotUntrusted(evidence) {
				t.Fatal("current application evidence rejected")
			}
			r.RecordChallengeSuccess(p.ID)
			heartbeatWarmWork(t, r, p, 8000, 8)
			model := p.Models[0].ID
			if got := r.warmPool.state.snapshot(time.Now(), time.Minute)[model].promptWork.count; got != 0 {
				t.Fatalf("policy recovery replayed excluded work: samples=%d", got)
			}
			// A routine generation refresh carrying the same approved proof
			// forward preserves the recovered baseline.
			r.SetReleasePolicyGeneration(2, true, func(ApplicationEvidence) bool { return true })
			heartbeatWarmWork(t, r, p, 16000, 16)
			if got := r.warmPool.state.snapshot(time.Now(), time.Minute)[model].promptWork.count; got != 8 {
				t.Fatalf("approved policy refresh discarded fresh work: samples=%d", got)
			}
		})
	}
}
