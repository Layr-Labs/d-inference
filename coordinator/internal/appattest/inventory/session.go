package inventory

import (
	"context"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/storage"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type SessionDependencies struct {
	Store    store.MachineInventoryStore
	Provider *registry.Provider
	Slots    chan struct{}
	Count    func(string, []string)
}

// Session records live identity observations independently of serving grants.
type Session struct {
	mu          sync.Mutex
	deps        SessionDependencies
	identity    store.MachineIdentity
	observation store.MachineObservation
	dropped     func() uint64
	ready       chan struct{}
	readyOnce   sync.Once
}

func NewSession(deps SessionDependencies, initial store.MachineObservation) *Session {
	return &Session{deps: deps, observation: initial, ready: make(chan struct{})}
}

func (x *Session) Ready() <-chan struct{} { return x.ready }

func (x *Session) TrackDropped(dropped func() uint64) {
	x.mu.Lock()
	x.dropped = dropped
	x.mu.Unlock()
}

func (x *Session) Identity() store.MachineIdentity {
	x.mu.Lock()
	defer x.mu.Unlock()
	return x.identity
}

func (x *Session) Observation() store.MachineObservation {
	x.mu.Lock()
	defer x.mu.Unlock()
	return x.observation
}

func (x *Session) CaptureIdentity() store.MachineIdentity {
	x.Capture(false)
	return x.Identity()
}

func (x *Session) count(name string, tags []string) {
	if x.deps.Count != nil {
		x.deps.Count(name, tags)
	}
}

func (x *Session) Capture(disconnected bool) {
	x.mu.Lock()
	o := x.observation
	if x.dropped != nil {
		o.ShadowDropped = x.dropped()
	}
	x.mu.Unlock()
	o.At, o.Disconnected = time.Now().UTC(), disconnected
	p := x.deps.Provider
	p.Mu().Lock()
	o.LegacyTrust, o.LegacyCode, o.LegacyMDA = string(p.TrustLevel), p.CodeAttested, p.MDAVerified
	if a := p.AttestationResult; a != nil && a.Valid && a.EncryptionPublicKey == p.PublicKey {
		o.SEKey = a.PublicKey
		if m := p.MDAResult; p.TrustLevel == registry.TrustHardware && p.MDAVerified && p.SEKeyBound && m != nil && m.Valid {
			o.VerifiedSerial = m.DeviceSerial
		}
	}
	p.Mu().Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if x.deps.Slots != nil {
		select {
		case x.deps.Slots <- struct{}{}:
			defer func() { <-x.deps.Slots }()
		case <-ctx.Done():
			x.count("app_attest.inventory.failed", []string{"reason:busy"})
			return
		}
	}
	id, err := x.deps.Store.ObserveMachine(ctx, o)
	if err != nil {
		x.count("app_attest.inventory.failed", []string{"reason:storage_error"})
		return
	}
	x.mu.Lock()
	x.identity = id
	x.mu.Unlock()
	x.readyOnce.Do(func() { close(x.ready) })
	x.count("app_attest.inventory.recorded", nil)
}

// RecordStatus retains signed facts even when readiness is unavailable. Only a
// known active credential supplies an alias; an empty alias clears prior state.
func (x *Session) recordStatus(status *protocol.AppAttestStatus, verifiedKey string) {
	x.mu.Lock()
	x.observation.VerifiedAppAttestKey = verifiedKey
	x.observation.OSSource = "app_attest_assertion_report"
	x.observation.OSObservedAt = time.Now().UTC()
	x.observation.OSVersion = status.OSVersion
	x.observation.OSMajor = ReportedOSMajor(status.OSVersion)
	x.observation.OSBuild = status.OSBuild
	x.mu.Unlock()
	x.Capture(false)
}

// ObserveAssertion preserves the verified status even on a readiness failure.
// Readiness only controls whether the credential may become an identity alias.
func (x *Session) ObserveAssertion(ctx context.Context, readiness store.AppAttestReadinessStore, keyID string, status *protocol.AppAttestStatus) (store.AppAttestReadiness, bool) {
	var state store.AppAttestReadiness
	known := false
	if readiness != nil {
		operation, cancel := context.WithTimeout(ctx, 2*time.Second)
		var err error
		state, err = readiness.GetAppAttestReadiness(operation, keyID)
		cancel()
		known = err == nil
	}
	if status != nil {
		alias := ""
		if known && !state.Revoked {
			alias = keyID
		}
		x.recordStatus(status, alias)
	}
	return state, known
}

func (x *Session) RecordEvent(scope *storage.Scope, session, stage, outcome string, fields map[string]any) (bool, error) {
	return observation.Record(scope, x.deps.Store, session, stage, outcome, fields)
}
