package service

import (
	"encoding/json"
	"fmt"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestIdentityCandidatePreservesLegacyOutsideServingCohort(t *testing.T) {
	for _, tc := range []struct {
		name, environment, account, version, os string
		percent, protocol                       int
		enabled, want                           bool
	}{
		{"production eligible", "production", "account", "0.9.4", "27.0", 100, 3, true, true},
		{"serving off", "production", "account", "0.9.4", "27.0", 100, 3, false, false},
		{"development", "development", "account", "0.9.4", "27.0", 100, 3, true, false},
		{"unknown environment", "", "account", "0.9.4", "27.0", 100, 3, true, false},
		{"rollout zero", "production", "account", "0.9.4", "27.0", 0, 3, true, false},
		{"invalid rollout", "production", "account", "0.9.4", "27.0", 101, 3, true, false},
		{"unauthenticated", "production", "", "0.9.4", "27.0", 100, 3, true, false},
		{"unsafe client", "production", "account", "0.9.3", "27.0", 100, 3, true, false},
		{"old protocol", "production", "account", "0.9.4", "27.0", 100, 2, true, false},
		{"older macOS", "production", "account", "0.9.4", "26.0.1", 100, 3, true, false},
		{"older verbose macOS", "production", "account", "0.9.4", "Version 26.2 (Build 25C10)", 100, 3, true, false},
		{"unknown OS still needs qualification", "production", "account", "0.9.4", "", 100, 3, true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := New(nil, Config{ServingEnabled: tc.enabled, Environment: tc.environment, RolloutPercent: tc.percent}, Dependencies{})
			report, _ := json.Marshal(map[string]any{"attestation": map[string]string{"osVersion": tc.os}})
			r := &protocol.RegisterMessage{Version: tc.version, AppAttestProtocol: tc.protocol, Attestation: report}
			if got := s.IdentityCandidate(r, tc.account); got != tc.want {
				t.Fatalf("candidate=%v want %v", got, tc.want)
			}
		})
	}
	s := New(nil, Config{ServingEnabled: true, Environment: "production", RolloutPercent: 37}, Dependencies{})
	r := &protocol.RegisterMessage{Version: "0.9.4", AppAttestProtocol: 3}
	included, excluded := false, false
	for i := 0; i < 100; i++ {
		account := fmt.Sprintf("account-%d", i)
		want := appAttestRolloutDecision(r.Version, account, "canonical-machine", 37) == "enabled"
		if s.IdentityCandidate(r, account) != want {
			t.Fatal("registration and exchange cohort decisions differ")
		}
		included, excluded = included || want, excluded || !want
	}
	if !included || !excluded {
		t.Fatal("partial-rollout fixture did not exercise both cohorts")
	}
}
