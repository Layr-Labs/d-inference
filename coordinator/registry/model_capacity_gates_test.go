package registry

import (
	"fmt"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"testing"
)

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

func TestModelCapacityPreservesFleetBreakerFallback(t *testing.T) {
	for _, health := range []bool{false, true} {
		for _, peer := range []string{"none", "healthy", "busy", "thermal", "broken template"} {
			t.Run(fmt.Sprintf("ejection=%v/peer=%s", health, peer), func(t *testing.T) {
				reg := New(testLogger())
				model := "capacity-breaker"
				bad := makeSchedulerProvider(t, reg, "bad", model, 100)
				if health {
					bad.AttestationResult = &attestation.VerificationResult{Valid: true, SerialNumber: "CAPACITY-BAD"}
					for range healthEjectionConsecTrip {
						reg.RecordProviderServeOutcome("serial:CAPACITY-BAD", false, 500, "boom")
					}
					if !reg.HealthEjectionOpen("serial:CAPACITY-BAD") {
						t.Fatal("ejection did not open")
					}
				} else {
					for range providerBreakerConsecTrip {
						reg.RecordProviderOutcome(bad.ID, false, 500, "boom")
					}
					if !reg.ProviderBreakerOpen(bad.ID) {
						t.Fatal("breaker did not open")
					}
				}
				if peer != "none" {
					p := makeSchedulerProvider(t, reg, "peer", model, 50)
					switch peer {
					case "busy":
						p.BackendCapacity.Slots[0].MaxConcurrency = 1
						p.AddPending(&PendingRequest{RequestID: "busy", Model: model})
					case "thermal":
						p.SystemMetrics.ThermalState = "critical"
					case "broken template":
						p.Models[0].TemplateRenderOK = boolPtr(false)
					}
				}
				capacity := reg.ModelCapacitySnapshot()
				request := &PendingRequest{RequestID: "probe", Model: model, RequestedMaxTokens: 1}
				selected, decision := reg.ReserveProviderEx(model, request)
				want := 1
				if peer == "busy" {
					want = 0
				}
				if (selected != nil) != (want > 0) || decision.CandidateCount != want {
					t.Fatalf("dispatch precondition: selected=%v decision=%+v", selected != nil, decision)
				}
				if len(capacity) != 1 || capacity[0].RoutableProviders != want || capacity[0].Ready != (want > 0) {
					t.Fatalf("capacity disagrees with dispatch cohort: %+v; want %d", capacity, want)
				}
			})
		}
	}
}
