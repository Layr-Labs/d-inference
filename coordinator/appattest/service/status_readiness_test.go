package service

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type statusReadinessStore struct {
	*store.MemoryStore
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
			st := &statusReadinessStore{MemoryStore: store.NewMemory(store.Config{}), state: store.AppAttestReadiness{Revoked: tc.revoked}, err: tc.err}
			s := &Service{store: st}
			p := newSessionProvider("endpoint", "se")
			capture := &captureInventory{}
			inventory := &machineInventorySession{s: s, p: p, store: capture, observation: store.MachineObservation{SessionID: p.ID, AccountID: "account", OSVersion: "26.0", VerifiedAppAttestKey: "previous-key"}}
			x := &Session{s: s, provider: p, inventory: inventory, account: "account", id: "connection", key: &store.AppAttestShadowKey{KeyID: "current-key"}, assertionAt: time.Now(), protocolVersion: 3}
			x.observeBuildPolicy(&protocol.AppAttestStatus{OSVersion: "27.0.0", OSBuild: "26A428"}, nil)
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
