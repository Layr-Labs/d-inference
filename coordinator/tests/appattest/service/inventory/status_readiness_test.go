package inventory_test

import (
	"context"
	"errors"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/inventory"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

type statusReadinessStore struct {
	*memorystore.MemoryStore
	state store.AppAttestReadiness
	err   error
}

func (s *statusReadinessStore) GetAppAttestReadiness(context.Context, string) (store.AppAttestReadiness, error) {
	return s.state, s.err
}

func TestAppAttestSignedStatusSurvivesReadinessFailureAndRevocation(t *testing.T) {
	for _, tc := range []struct {
		name    string
		revoked bool
		err     error
		alias   string
	}{
		{"lookup failed", false, errors.New("temporary storage failure"), ""},
		{"revoked", true, nil, ""},
		{"known active", false, nil, "current-key"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			st := &statusReadinessStore{MemoryStore: memorystore.NewMemory(store.Config{}), state: store.AppAttestReadiness{Revoked: tc.revoked}, err: tc.err}
			p := &registry.Provider{ID: "p1", PublicKey: "endpoint"}
			capture := &captureInventory{}
			x := inventory.NewSession(inventory.SessionDependencies{Store: capture, Provider: p}, store.MachineObservation{SessionID: p.ID, AccountID: "account", OSVersion: "26.0", VerifiedAppAttestKey: "previous-key"})
			x.ObserveAssertion(context.Background(), st, "current-key", &protocol.AppAttestStatus{OSVersion: "27.0.0", OSBuild: "26A428"})
			o := capture.observation
			if o.OSVersion != "27.0.0" || o.OSBuild != "26A428" || o.OSMajor != 27 || o.OSSource != "app_attest_assertion_report" {
				t.Fatalf("signed status lost: %+v", o)
			}
			if o.VerifiedAppAttestKey != tc.alias {
				t.Fatalf("readiness failure attached alias %q", o.VerifiedAppAttestKey)
			}
		})
	}
}
