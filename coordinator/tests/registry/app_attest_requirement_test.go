package registry_test

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestAppAttestRequirementRejectsLegacySubstitution(t *testing.T) {
	for _, state := range []string{"pending", "unsupported_os", "unsupported_protocol", "expired", "cleared", "policy_disabled", "qualification_changed"} {
		t.Run(state, func(t *testing.T) {
			clock := &appAttestTestClock{}
			gatesRegistry := newGateCharacterizationRegistry(production.Dependencies{AppAttestNow: clock.Now})
			r, p, lease := appAttestTestProvider(t, gatesRegistry.Registry)
			p.RequireAppAttestServingAuthorization()
			if state == "expired" || state == "cleared" || state == "policy_disabled" || state == "qualification_changed" {
				if !r.GrantAppAttestServingAuthorization(p, lease) {
					t.Fatal("grant")
				}
			}
			switch state {
			case "expired":
				clock.Store(lease.ValidUntil.UnixNano())
			case "cleared":
				r.ClearAppAttestServingAuthorization(p)
			case "policy_disabled":
				r.SetAppAttestServingPolicy(false, lease.PolicyGeneration)
			case "qualification_changed":
				r.SetAppAttestQualificationGeneration(1)
			}
			// Registry knows only the connection requirement, not why the API
			// cannot grant a lease (pending verification, OS or protocol).
			p.Mu().Lock()
			testMakeTextRoutable(p)
			p.CodeAttested = true
			p.Mu().Unlock()
			if r.ProviderLegacyServingAuthorized(p) || r.ProviderOwnerServingAuthorized(p) {
				t.Fatal("legacy readiness bypassed the connection requirement")
			}
			if models := r.OwnedModels(lease.AccountID); len(models) != 0 {
				t.Fatalf("owner models advertised without required lease: %+v", models)
			}
			gates := collectGateOutcomes(gatesRegistry, p, appAttestTestModel, time.Now())
			if gates.routingGates || gates.routingGatesSelf || gates.routingGatesBypass || gates.canRoutePublic || gates.canRouteRelaxed || gates.hasWarm || gates.publiclyRoutable || gates.modelLoadCand || gates.warmReason != warmplan.WarmColdTrust {
				t.Fatalf("required lease bypassed by routing/load/warm gate: %+v", gates)
			}
			for _, route := range []string{"public", "self", "prefer"} {
				pr := &production.PendingRequest{RequestID: route, Model: appAttestTestModel, OwnerAccountID: lease.AccountID, SelfRouteOnly: route == "self", PreferOwner: route == "prefer"}
				if r.ReserveProvider(appAttestTestModel, pr) != nil {
					t.Fatalf("%s routed without required lease", route)
				}
			}
			if snapshot, ok := r.GetProviderRewardSnapshot(p.ID); !ok || snapshot.ServingAuthorized {
				t.Fatal("snapshot advertised legacy serving authorization")
			}
		})
	}
}

func TestAppAttestRequirementOwnerFinalHandoff(t *testing.T) {
	for _, route := range []string{"self", "prefer"} {
		for _, state := range []string{"valid", "expired", "cleared"} {
			t.Run(route+"/"+state, func(t *testing.T) {
				clock := &appAttestTestClock{}
				frames := &atomic.Int32{}
				w := newWriterFixture(8, 8, nil, nil, func([]byte) error { frames.Add(1); return nil }, nil)
				t.Cleanup(w.Close)
				r, p, lease := appAttestTestProvider(t, production.NewWithDependencies(testLogger(), production.Dependencies{
					AppAttestNow: clock.Now,
					Connections:  retainedWriterFactory{writer: w.Writer},
				}))
				p.RequireAppAttestServingAuthorization()
				p.RequireAppAttestServingAuthorization() // Repeated onboarding cannot weaken it.
				p.Mu().Lock()
				testMakeTextRoutable(p)
				p.CodeAttested = true
				p.PrivateOnly = true
				p.Mu().Unlock()
				if !r.GrantAppAttestServingAuthorization(p, lease) {
					t.Fatal("grant")
				}
				if !r.ProviderOwnerServingAuthorized(p) || r.ProviderLegacyServingAuthorized(p) {
					t.Fatal("required connection readiness did not use App Attest")
				}
				if models := r.OwnedModels(lease.AccountID); len(models) != 1 || models[0].ID != appAttestTestModel {
					t.Fatalf("valid lease did not advertise owner model: %+v", models)
				}
				go w.Run()
				pr := &production.PendingRequest{RequestID: "owner-inference", Model: appAttestTestModel, OwnerAccountID: lease.AccountID, SelfRouteOnly: route == "self", PreferOwner: route == "prefer"}
				if r.ReserveProvider(appAttestTestModel, pr) != p {
					t.Fatal("valid lease did not allow owner reservation")
				}
				ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
				defer cancel()
				metadata, err := p.WriteInferenceTextDeferred(ctx, pr, func(time.Time) ([]byte, error) { return []byte("sealed inference"), nil }, func(production.TextFrameWriteMetadata) {
					switch state {
					case "expired":
						clock.Store(lease.ValidUntil.UnixNano())
					case "cleared":
						r.ClearAppAttestServingAuthorization(p)
					}
				})
				if state == "valid" {
					if err != nil || !metadata.Committed || frames.Load() != 1 {
						t.Fatalf("valid handoff: metadata=%+v err=%v frames=%d", metadata, err, frames.Load())
					}
				} else if !errors.Is(err, production.ErrProviderServingUnauthorized) || metadata.Committed || frames.Load() != 0 {
					t.Fatalf("unauthorized handoff: metadata=%+v err=%v frames=%d", metadata, err, frames.Load())
				}
			})
		}
	}
}

func TestAppAttestRequirementDoesNotChangeLegacyConnections(t *testing.T) {
	r, p, _ := appAttestTestProvider(t)
	p.Mu().Lock()
	testMakeTextRoutable(p)
	p.CodeAttested = true
	p.Mu().Unlock()
	if !r.ProviderLegacyServingAuthorized(p) || !r.ProviderOwnerServingAuthorized(p) {
		t.Fatal("unflagged legacy connection lost readiness")
	}
	if models := r.OwnedModels("account-1"); len(models) != 1 || models[0].ID != appAttestTestModel {
		t.Fatalf("unflagged legacy connection lost owner model: %+v", models)
	}
	for _, route := range []string{"public", "self", "prefer"} {
		pr := &production.PendingRequest{RequestID: route, Model: appAttestTestModel, OwnerAccountID: "account-1", SelfRouteOnly: route == "self", PreferOwner: route == "prefer"}
		if r.ReserveProvider(appAttestTestModel, pr) != p {
			t.Fatalf("legacy %s route rejected", route)
		}
		p.RemovePending(pr.RequestID)
	}
	p.Mu().Lock()
	p.TrustLevel = production.TrustLevel("unknown")
	p.Mu().Unlock()
	if models := r.OwnedModels("account-1"); len(models) != 1 || models[0].ID != appAttestTestModel {
		t.Fatalf("unflagged owner listing changed for unknown trust: %+v", models)
	}
}
