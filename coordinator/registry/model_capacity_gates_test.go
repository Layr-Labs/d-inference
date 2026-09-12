package registry

import "testing"

func TestModelCapacityDoesNotAdvertiseStructurallyExcludedPairs(t *testing.T) {
	for _, tc := range []struct {
		name    string
		exclude func(*Registry, *Provider)
	}{
		{"broken template", func(_ *Registry, p *Provider) {
			p.mu.Lock()
			p.Models[0].TemplateRenderOK = boolPtr(false)
			p.mu.Unlock()
		}},
		{"mixed dedicated family", func(r *Registry, p *Provider) {
			r.SetDedicatedModels([]string{"gemma-4"})
			addAdvertisedModel(p, qwenBuild)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reg := New(testLogger())
			p := makeSchedulerProvider(t, reg, "excluded", gemmaBuild, 100)
			initial := reg.ModelCapacitySnapshot()
			if len(initial) != 1 || !initial[0].Ready || initial[0].RoutableProviders != 1 {
				t.Fatalf("healthy pair must initially be ready: %+v", initial)
			}
			tc.exclude(reg, p)
			request := &PendingRequest{RequestID: "excluded", Model: gemmaBuild, RequestedMaxTokens: 64}
			if selected, _ := reg.ReserveProviderEx(gemmaBuild, request); selected != nil {
				t.Fatal("precondition: routing must exclude this provider/model pair")
			}
			found := false
			for _, capacity := range reg.ModelCapacitySnapshot() {
				if capacity.ModelID != gemmaBuild {
					continue
				}
				found = true
				if capacity.Ready || capacity.CanAccept || capacity.RoutableProviders != 0 {
					t.Fatalf("unroutable pair advertised ready: %+v", capacity)
				}
				if capacity.WarmProviders != 1 {
					t.Fatalf("excluded pair lost its resident inventory: %+v", capacity)
				}
			}
			if !found {
				t.Fatal("excluded pair disappeared from model inventory")
			}
		})
	}
}
