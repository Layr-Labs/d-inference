package authorization_test

import (
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/authorization"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestRetainedRecordSnapshotsCallerEvidenceAndPolicyInputs(t *testing.T) {
	f, p, record, state := newAuthorizationFixture(t, false)
	*f.evidence.ValidationCategory = 1
	f.evidence.CodeDirectoryHash = strings.Repeat("e", 64)
	f.status.BinaryHash = strings.Repeat("d", 64)
	if !f.controller.Apply(p, record, state, time.Now()) {
		t.Fatal("caller mutation changed retained verified evidence")
	}
	policy := f.policy()
	approve := policy.Approves
	mutate := true
	policy.Approves = func(p *registry.Provider, status *protocol.AppAttestStatus) bool {
		approved := approve(p, status)
		if mutate {
			mutate = false
			status.BinaryHash = strings.Repeat("e", 64)
		}
		return approved
	}
	f.policy = func() *authorization.ReleasePolicy { return policy }
	if f.controller.Apply(p, record, state, time.Now()) {
		t.Fatal("qualification did not see the current callback input")
	}
	if !f.controller.Apply(p, record, state, time.Now()) {
		t.Fatal("policy callback mutation escaped its decision snapshot")
	}
}
