// Package authorization owns verified-proof replacement, readiness refresh and
// live serving grants. It never performs cryptography or retains proof bytes.
package authorization

import (
	"context"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/eligibility"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const RefreshInterval = 5 * time.Second
const RevocationFreshness = 30 * time.Second

// ReleasePolicy is one immutable catalog generation. The approval callback
// must close over that same generation, not fetch another catalog snapshot.
type ReleasePolicy struct {
	Generation               uint64
	Known                    bool
	Approves                 func(*registry.Provider, *protocol.AppAttestStatus) bool
	ContainsQualifiedRelease func(store.Release) bool
}

type Dependencies struct {
	Readiness     func() store.AppAttestReadinessBatchStore
	Registry      *registry.Registry
	ReleasePolicy func() *ReleasePolicy
	Qualify       func(*appattest.AuthorizationEvidence, *protocol.AppAttestStatus, *ReleasePolicy) (uint64, time.Time)
	Notify        func(*registry.Provider)
	Revoke        func(string)
	Count         func(string)
	Notifications *Outbox
}

// Record is a retained cryptographically verified proof, independent of a
// receipt/readiness snapshot. Its identity is used to fence stale refreshes.
type Record struct {
	proof VerifiedProof
}

func NewRecord(e appattest.AuthorizationEvidence, status protocol.AppAttestStatus, session string, dropped func() uint64, baseline uint64) *Record {
	return &Record{proof: NewVerifiedProof(e, &status, session, dropped, baseline)}
}

type Controller struct {
	mu      sync.Mutex
	deps    Dependencies
	current map[*registry.Provider]*Record
	post    *Outbox
}

func New(deps Dependencies) *Controller {
	return &Controller{deps: deps, current: make(map[*registry.Provider]*Record), post: deps.Notifications}
}

func (a *Controller) Remember(p *registry.Provider, record *Record) {
	a.mu.Lock()
	a.current[p] = record
	a.mu.Unlock()
}

func (a *Controller) Current(p *registry.Provider) *Record {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.current[p]
}

func (a *Controller) Forget(p *registry.Provider) {
	if a == nil {
		return
	}
	a.mu.Lock()
	delete(a.current, p)
	a.deps.Registry.ClearAppAttestServingAuthorization(p)
	a.queuePostLocked(p)
	a.mu.Unlock()
}

// RejectProof hard-denies only authenticated proof violations. Unsigned reply
// mismatches and transient failures cannot revoke independent legacy trust.
func (a *Controller) RejectProof(p *registry.Provider, reason string) {
	if a == nil || !eligibility.ProofViolation(reason) {
		return
	}
	a.Forget(p)
	a.deps.Registry.MarkUntrusted(p.ID)
	if a.deps.Notify != nil {
		a.deps.Notify(p)
	}
}

func (a *Controller) Revoke(keyID string) {
	affected := a.deps.Registry.RevokeAppAttestCredential(keyID)
	var presenters []*registry.Provider
	a.mu.Lock()
	for p, record := range a.current {
		if record.proof.evidence.Binding.Credential == keyID {
			delete(a.current, p)
			presenters = append(presenters, p)
		}
	}
	a.mu.Unlock()
	for _, p := range presenters {
		if a.deps.Registry.DenyAppAttestProvider(p) {
			a.QueueStatus(p)
		}
	}
	for _, id := range affected {
		a.QueueStatus(a.deps.Registry.GetProvider(id))
	}
}

func (a *Controller) QueueStatus(p *registry.Provider) {
	if p == nil {
		return
	}
	a.mu.Lock()
	a.queuePostLocked(p)
	a.mu.Unlock()
}

// Drop advances the evidence-gap audit under the same critical section as the
// final grant check. A visible gap must never precede a concurrent fresh grant.
func (a *Controller) Drop(p *registry.Provider, counter *atomic.Uint64) {
	a.mu.Lock()
	counter.Add(1)
	delete(a.current, p)
	a.deps.Registry.ClearAppAttestServingAuthorization(p)
	a.queuePostLocked(p)
	a.mu.Unlock()
}

func (a *Controller) Start(ctx context.Context, launch func(string, func())) {
	if a.post == nil {
		a.post = NewOutbox(256)
	}
	for range 4 {
		launch("appAttestServingNotifications", func() {
			for {
				p, ok := a.post.Next(ctx)
				if !ok {
					return
				}
				a.deps.Registry.RefreshAppAttestServingState(p)
				a.deps.Registry.DisconnectDuplicatesByMachine(p)
				if a.deps.Notify != nil {
					a.deps.Notify(p)
				}
				a.mu.Lock()
				a.post.Complete(p)
				a.mu.Unlock()
			}
		})
	}
	launch("appAttestAuthorizer", func() {
		ticker := time.NewTicker(RefreshInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				a.Refresh(ctx)
			}
		}
	})
}

// Writer delays never occupy the policy lock or readiness refresh worker.
func (a *Controller) queuePostLocked(p *registry.Provider) {
	if a.post != nil {
		a.post.Offer(p)
	}
}

func (a *Controller) Refresh(ctx context.Context) {
	if a.deps.Readiness == nil {
		return
	}
	st := a.deps.Readiness()
	if st == nil {
		return
	}
	a.mu.Lock()
	records := make(map[*registry.Provider]*Record, len(a.current))
	keys := make([]string, 0, len(a.current))
	seen := make(map[string]bool)
	for p, record := range a.current {
		if a.deps.Registry.GetProvider(p.ID) != p {
			delete(a.current, p)
			continue
		}
		records[p] = record
		key := record.proof.evidence.Binding.Credential
		if !seen[key] {
			keys = append(keys, key)
			seen[key] = true
		}
	}
	a.mu.Unlock()
	for _, credentials := range a.deps.Registry.VerifiedAppAttestPresenters() {
		for _, key := range credentials {
			if !seen[key] {
				keys = append(keys, key)
				seen[key] = true
			}
		}
	}
	for start := 0; start < len(keys); start += 1000 {
		end := min(start+1000, len(keys))
		observedAt := time.Now().UTC()
		operation, cancel := context.WithTimeout(ctx, 3*time.Second)
		states, err := st.GetAppAttestReadinessBatch(operation, keys[start:end])
		cancel()
		if err != nil {
			if a.deps.Count != nil {
				a.deps.Count("app_attest.authorization.refresh_failed")
			}
			continue
		}
		batch := make(map[string]bool, end-start)
		for _, key := range keys[start:end] {
			batch[key] = true
			if states[key].Revoked && a.deps.Revoke != nil {
				a.deps.Revoke(key)
			}
		}
		for p, record := range records {
			key := record.proof.evidence.Binding.Credential
			if !batch[key] {
				continue
			}
			state, exists := states[key]
			a.mu.Lock()
			if a.current[p] != record {
				a.mu.Unlock()
				continue
			}
			if state.Revoked {
				a.deps.Registry.RevokeAppAttestCredential(key)
				delete(a.current, p)
				a.queuePostLocked(p)
			} else if !exists {
				a.queuePostLocked(p)
			} else {
				a.applyLocked(p, record, state, observedAt)
			}
			a.queuePostLocked(p)
			a.mu.Unlock()
			if state.Revoked {
				a.deps.Registry.DenyAppAttestProvider(p)
			}
		}
	}
}

// ApplyCurrent fences a readiness read with the exact remembered proof. A late
// response cannot apply after a drop, revocation, or replacement.
func (a *Controller) ApplyCurrent(p *registry.Provider, record *Record, state store.AppAttestReadiness, observedAt time.Time) (bool, string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.current[p] != record {
		return false, "proof_replaced"
	}
	if state.Revoked {
		return false, "credential_revoked"
	}
	return a.applyLocked(p, record, state, observedAt)
}

func (a *Controller) Apply(p *registry.Provider, record *Record, state store.AppAttestReadiness, observedAt time.Time) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	granted, _ := a.applyLocked(p, record, state, observedAt)
	return granted
}

func (a *Controller) applyLocked(p *registry.Provider, record *Record, state store.AppAttestReadiness, observedAt time.Time) (bool, string) {
	proof := NewVerifiedProof(record.proof.evidence, &record.proof.status, record.proof.session, record.proof.dropped, record.proof.baseline)
	e, status := proof.evidence, proof.status
	eligibility.ApplyReadiness(&e, state)
	if proof.dropped != nil && proof.dropped() > proof.baseline {
		e.ArchiveComplete = false
		a.deps.Registry.ClearAppAttestServingAuthorization(p)
		a.queuePostLocked(p)
		return false, "archive_gap"
	}
	snapshot := a.deps.ReleasePolicy()
	e.CatalogKnown = snapshot != nil && snapshot.Known
	e.BuildMatched = snapshot != nil && snapshot.Known && snapshot.Approves != nil && snapshot.Approves(p, &status)
	qualificationGeneration, qualificationUntil := a.deps.Qualify(&e, &status, snapshot)
	verdict := appattest.EvaluateAuthorization(e, time.Now().UTC())
	if verdict.Outcome != "eligible" || snapshot == nil {
		if verdict.Outcome != "unknown" {
			a.deps.Registry.ClearAppAttestServingAuthorization(p)
		}
		a.queuePostLocked(p)
		if verdict.Outcome == "unknown" {
			return false, "policy_unknown"
		}
		return false, "policy_ineligible"
	}
	until := minTime(verdict.ValidUntil, observedAt.Add(RevocationFreshness))
	until = minTime(until, qualificationUntil)
	lease := registry.AppAttestServingAuthorization{
		AccountID: e.Binding.Account, MachineID: e.Binding.Machine, CredentialID: e.Binding.Credential,
		ConnectionID: p.ID, ProofSessionID: proof.session, Endpoint: e.Binding.Endpoint,
		PolicyGeneration: snapshot.Generation, QualificationGeneration: qualificationGeneration, IssuedAt: e.AssertionAt, ValidUntil: until,
		MachineModel: status.MachineModel, OSVersion: status.OSVersion,
	}
	lease.MemoryGB, _ = strconv.Atoi(status.MemoryGB)
	if !a.deps.Registry.GrantAppAttestServingAuthorization(p, lease) {
		return false, "grant_rejected"
	}
	a.queuePostLocked(p)
	if a.deps.Count != nil {
		a.deps.Count("app_attest.authorization.renewed")
	}
	return true, "granted"
}

func minTime(a, b time.Time) time.Time {
	if b.Before(a) {
		return b
	}
	return a
}
