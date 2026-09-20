package service

import (
	"context"
	"strconv"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const appAttestAuthorizationRefresh = 5 * time.Second
const appAttestRevocationFreshness = 30 * time.Second

// The durable revocation/receipt snapshot has a separate, short lifetime from
// the cryptographic assertion. No database work runs on the dispatch path.
// A remote revocation or unavailable store fences new dispatch within 30s;
// revocation through this server's admin handler fences immediately.
type authorizer struct {
	mu          sync.Mutex
	s           *Service
	current     map[*registry.Provider]*appAttestAuthorizationRecord
	post        chan *registry.Provider
	postPending map[*registry.Provider]bool
}

type appAttestAuthorizationRecord struct {
	evidence     appattest.AuthorizationEvidence
	status       protocol.AppAttestStatus
	proofSession string
	dropped      func() uint64
}

func (s *Service) startAppAttestAuthorizer(ctx context.Context) {
	if !s.config.ServingEnabled || s.config.Environment != "production" {
		return
	}
	a := &authorizer{s: s, current: make(map[*registry.Provider]*appAttestAuthorizationRecord)}
	a.post, a.postPending = make(chan *registry.Provider, 256), make(map[*registry.Provider]bool)
	s.authorizer = a
	_, generation := s.registry.AppAttestServingPolicy()
	s.registry.SetAppAttestServingPolicy(true, generation)
	for range 4 {
		saferun.Go(s.logger, "appAttestServingNotifications", func() {
			for {
				select {
				case <-ctx.Done():
					return
				case p := <-a.post:
					s.registry.RefreshAppAttestServingState(p)
					s.registry.DisconnectDuplicatesByMachine(p)
					s.sendAppAttestAuthorizationStatus(p)
					a.mu.Lock()
					delete(a.postPending, p)
					a.mu.Unlock()
				}
			}
		})
	}
	saferun.Go(s.logger, "appAttestAuthorizer", func() {
		ticker := time.NewTicker(appAttestAuthorizationRefresh)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				a.refresh(ctx)
			}
		}
	})
}

func (a *authorizer) remember(p *registry.Provider, record *appAttestAuthorizationRecord) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.current[p] = record
}

func (a *authorizer) forget(p *registry.Provider) {
	if a == nil {
		return
	}
	a.mu.Lock()
	delete(a.current, p)
	a.s.registry.ClearAppAttestServingAuthorization(p)
	a.queuePostLocked(p)
	a.mu.Unlock()
}

// Called under mu. User-controlled writer delays never run on the policy or
// revocation refresh worker. Queue saturation only delays notifications and
// promotion; direct authorization checks still fail closed.
func (a *authorizer) queuePostLocked(p *registry.Provider) {
	if a.post == nil || a.postPending[p] {
		return
	}
	select {
	case a.post <- p:
		a.postPending[p] = true
	default:
	}
}

func (a *authorizer) refresh(ctx context.Context) {
	st, ok := store.As[store.AppAttestReadinessBatchStore](a.s.store)
	if !ok {
		return
	} // Existing grants expire; never extend unknown state.
	a.mu.Lock()
	records := make(map[*registry.Provider]*appAttestAuthorizationRecord, len(a.current))
	keys := make([]string, 0, len(a.current))
	seen := make(map[string]bool)
	for p, record := range a.current {
		if a.s.registry.GetProvider(p.ID) != p {
			delete(a.current, p)
			continue
		}
		records[p] = record
		key := record.evidence.Binding.Credential
		if !seen[key] {
			keys = append(keys, key)
			seen[key] = true
		}
	}
	a.mu.Unlock()
	// Presenter-only evidence carries no grantable record, but a newly revoked
	// credential must still fence its legacy-authorized current connection.
	for _, credentials := range a.s.registry.VerifiedAppAttestPresenters() {
		for _, key := range credentials {
			if !seen[key] {
				keys = append(keys, key)
				seen[key] = true
			}
		}
	}
	for start := 0; start < len(keys); start += 1000 {
		end := min(start+1000, len(keys))
		observedAt := time.Now().UTC() // Start time bounds even a slow query.
		operation, cancel := context.WithTimeout(ctx, 3*time.Second)
		states, err := st.GetAppAttestReadinessBatch(operation, keys[start:end])
		cancel()
		if err != nil {
			a.s.ddIncr("app_attest.authorization.refresh_failed", nil)
			continue
		}
		batch := make(map[string]bool, end-start)
		for _, key := range keys[start:end] {
			batch[key] = true
			if states[key].Revoked {
				a.s.RevokeCredential(key)
			}
		}
		for p, record := range records {
			key := record.evidence.Binding.Credential
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
				a.s.registry.RevokeAppAttestCredential(key)
				delete(a.current, p)
				a.queuePostLocked(p)
			} else if !exists {
				// Missing readiness is unknown, not a revocation. Keep the
				// existing lease deadline and record; no grant occurs here.
				a.queuePostLocked(p)
			} else {
				a.apply(p, record, state, observedAt)
			}
			a.queuePostLocked(p)
			a.mu.Unlock()
			if state.Revoked {
				// A verified record may precede the first successful grant.
				// Fence that current connection even if it has no credential index.
				a.s.registry.DenyAppAttestProvider(p)
			}
		}
	}
}

// Caller serializes replacement/invalidation with mu. A registry grant also
// checks the exact live connection, endpoint and current policy generation.
func (a *authorizer) apply(p *registry.Provider, record *appAttestAuthorizationRecord, state store.AppAttestReadiness, observedAt time.Time) bool {
	e := record.evidence
	applyAppAttestReadiness(&e, state)
	if record.dropped != nil && record.dropped() > 0 {
		e.ArchiveComplete = false
	}
	snapshot := a.s.currentReleasePolicySnapshot()
	e.CatalogKnown = snapshot != nil && snapshot.Known
	e.BuildMatched = appAttestReleaseApproved(snapshot, p, &record.status)
	verdict := appattest.EvaluateAuthorization(e, time.Now().UTC())
	if verdict.Outcome != "eligible" || snapshot == nil {
		if verdict.Outcome != "unknown" {
			a.s.registry.ClearAppAttestServingAuthorization(p)
		}
		a.queuePostLocked(p)
		return false
	}
	until := minAuthorizationTime(verdict.ValidUntil, observedAt.Add(appAttestRevocationFreshness))
	lease := registry.AppAttestServingAuthorization{
		AccountID: e.Binding.Account, MachineID: e.Binding.Machine, CredentialID: e.Binding.Credential,
		ConnectionID: p.ID, ProofSessionID: record.proofSession, Endpoint: e.Binding.Endpoint,
		PolicyGeneration: snapshot.Generation, IssuedAt: e.AssertionAt, ValidUntil: until,
		MachineModel: record.status.MachineModel,
	}
	lease.MemoryGB, _ = strconv.Atoi(record.status.MemoryGB)
	if !a.s.registry.GrantAppAttestServingAuthorization(p, lease) {
		return false
	}
	a.queuePostLocked(p)
	a.s.ddIncr("app_attest.authorization.renewed", nil)
	return true
}

func minAuthorizationTime(a, b time.Time) time.Time {
	if b.Before(a) {
		return b
	}
	return a
}
