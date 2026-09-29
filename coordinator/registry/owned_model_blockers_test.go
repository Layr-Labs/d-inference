package registry

import (
	"slices"
	"testing"
	"time"
)

func TestOwnedModelRoutingBlockers(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*Registry, *Provider)
		want   string
	}{
		{"servable", func(*Registry, *Provider) {}, ""},
		{"runtime", func(_ *Registry, p *Provider) { p.RuntimeVerified = false }, "runtime_unverified"},
		{"challenge", func(_ *Registry, p *Provider) { p.LastChallengeVerified = time.Time{} }, "challenge_stale"},
		{"template", func(_ *Registry, p *Provider) { p.Models[0].TemplateRenderOK = new(bool) }, "template_render_failed"},
		{"hash", func(r *Registry, p *Provider) {
			r.modelCatalog = map[string]CatalogEntry{"model": {ID: "model", WeightHash: "approved"}}
			p.Models[0].WeightHash = "stale"
		}, "model_hash_mismatch"},
		{"loaded_unadvertised", func(_ *Registry, p *Provider) { p.Models = nil }, "model_not_advertised"},
		{"legacy_loaded_unadvertised", func(_ *Registry, p *Provider) {
			p.Models, p.BackendCapacity, p.CurrentModel = nil, nil, "model"
		}, "model_not_advertised"},
		{"absent", func(_ *Registry, p *Provider) {
			p.Models = nil
			p.BackendCapacity.Slots[0].Model = "other"
		}, ""},
		{"authoritative_cold_slot", func(_ *Registry, p *Provider) {
			p.Models, p.CurrentModel = nil, "model"
			p.BackendCapacity.Slots[0].State = "idle_shutdown"
		}, ""},
		{"other_owner", func(_ *Registry, p *Provider) { p.AccountID = "stranger"; p.RuntimeVerified = false }, ""},
		{"offline", func(_ *Registry, p *Provider) { p.Status = StatusOffline; p.RuntimeVerified = false }, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := New(testLogger())
			p := makeSchedulerProvider(t, r, "provider", "model", 100)
			setProviderAccount(p, "owner")
			r.mu.Lock()
			p.mu.Lock()
			tc.change(r, p)
			p.syncModelIndexLocked()
			p.mu.Unlock()
			r.mu.Unlock()
			got := r.OwnedModelRoutingBlockers("owner", "model")
			var want []string
			if tc.want != "" {
				want = []string{tc.want}
				if _, serves := r.OwnedProviderSummary("owner", "model", RequestTraits{}, false); serves != 0 {
					t.Fatal("diagnostic blocks a provider the base-shape summary admits")
				}
			}
			if !slices.Equal(got, want) {
				t.Fatalf("blockers = %v, want %v", got, want)
			}
			if got := r.OwnedModelRoutingBlockers("", "model"); len(got) != 0 {
				t.Fatalf("empty owner leaked blockers: %v", got)
			}
		})
	}
}

func TestOwnedModelRoutingBlockersDeduplicateAndSort(t *testing.T) {
	r := New(testLogger())
	for _, id := range []string{"one", "two", "three"} {
		p := makeSchedulerProvider(t, r, id, "model", 100)
		p.mu.Lock()
		p.AccountID = "owner"
		if id == "three" {
			p.Models[0].TemplateRenderOK = new(bool)
		} else {
			p.RuntimeVerified = false
		}
		p.mu.Unlock()
	}
	if got, want := r.OwnedModelRoutingBlockers("owner", "model"), []string{"runtime_unverified", "template_render_failed"}; !slices.Equal(got, want) {
		t.Fatalf("blockers = %v, want %v", got, want)
	}
}
