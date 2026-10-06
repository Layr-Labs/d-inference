package registry_test

import (
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

const versionResetSerial = "SER-UPGRADE"
const versionResetStable = "serial:" + versionResetSerial

type versionGateClock struct{ ns atomic.Int64 }

func (c *versionGateClock) now() time.Time   { return time.Unix(0, c.ns.Load()) }
func (c *versionGateClock) set(at time.Time) { c.ns.Store(at.UnixNano()) }

func newVersionGateRegistry(at time.Time) (*production.Registry, *identitygate.Directory, *versionGateClock) {
	clock := new(versionGateClock)
	clock.set(at)
	options := identitygate.DefaultOptions()
	options.Now = clock.now
	gates := identitygate.New(testLogger(), &options)
	return production.NewWithDependencies(testLogger(), production.Dependencies{IdentityGates: gates}), gates, clock
}

// Exercise both registration orderings: version before attestation, and the
// later SetVersion call after the identity has already been bound.
func bindVersionedSession(t *testing.T, r *production.Registry, id, version string, versionFirst bool) *production.Provider {
	t.Helper()
	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{{ID: "m", ModelType: "chat"}}
	p := r.Register(id, nil, msg)
	bind := func() {
		p.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: versionResetSerial})
	}
	if versionFirst {
		p.SetVersion(version)
		bind()
	} else {
		bind()
		p.SetVersion(version)
	}
	return p
}

func dieAbruptlyWithFlush(t *testing.T, r *production.Registry, id string) {
	t.Helper()
	dieAbruptlyWithFlushKeyed(t, r, id, versionResetStable)
}

// Park three requests and reproduce the completion-side flush into all three
// fault trackers after an actual abrupt disconnect.
func dieAbruptlyWithFlushKeyed(t *testing.T, r *production.Registry, id, stable string) {
	t.Helper()
	p := r.GetProvider(id)
	if p == nil {
		t.Fatalf("provider %s not registered", id)
	}
	for i := 0; i < 3; i++ {
		p.AddPending(&production.PendingRequest{
			RequestID: fmt.Sprintf("%s-req-%d", id, i),
			Model:     "m",
			ErrorCh:   make(chan protocol.InferenceErrorMessage, 1),
		})
	}
	r.DisconnectWithReason(id, production.DisconnectReasonReadError)
	if sid := r.GetProviderStableIdentity(id); sid != stable {
		t.Fatalf("stable identity after disconnect = %q, want %q", sid, stable)
	}
	for i := 0; i < 2; i++ {
		r.RecordInferenceError(id, "m", 502, "base", protocol.CoordinatorCauseProviderDisconnected)
	}
	for i := 0; i < 5; i++ {
		r.RecordProviderOutcome(id, false, 502, "provider disconnected", protocol.CoordinatorCauseProviderDisconnected)
	}
	for i := 0; i < 8; i++ {
		r.RecordProviderServeOutcome(stable, false, 502, "provider disconnected", protocol.CoordinatorCauseProviderDisconnected)
	}
}

func assertIdentityQuarantine(t *testing.T, r *production.Registry, queryID string, want bool) {
	t.Helper()
	assertIdentityQuarantineKeyed(t, r, queryID, versionResetStable, want)
}

func assertIdentityQuarantineKeyed(t *testing.T, r *production.Registry, queryID, stable string, want bool) {
	t.Helper()
	if got := r.InferenceErrorCooldownActive(queryID, "m", "base"); got != want {
		t.Errorf("InferenceErrorCooldownActive(%s) = %v, want %v", queryID, got, want)
	}
	if got := r.ProviderBreakerOpen(queryID); got != want {
		t.Errorf("ProviderBreakerOpen(%s) = %v, want %v", queryID, got, want)
	}
	if got := r.HealthEjectionOpen(stable); got != want {
		t.Errorf("HealthEjectionOpen(%s) = %v, want %v", stable, got, want)
	}
}
