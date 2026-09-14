package codeidentity

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Observation is authorized by an already verified connection, not by a
// heartbeat claiming a version/token. Capture the timestamp with the flags.
// Only final disconnect stamping may observe the just-offlined connection;
// periodic and shutdown sweeps must not extend coverage for offline providers.
func (s *Manager) codeCoverageObservation(p *registry.Provider, allowOffline bool) (store.CodeAttestation, bool) {
	if p == nil || s.state == nil {
		return store.CodeAttestation{}, false
	}
	p.Mu().Lock()
	at := s.state.now().Truncate(time.Microsecond)
	statusAllowed := p.Status == registry.StatusOnline || (allowOffline && p.Status == registry.StatusOffline)
	if !p.CodeAttested || !p.FreshCodeAttested || !statusAllowed || p.TrustLevel != registry.TrustHardware || p.AttestationResult == nil || !p.AttestationResult.Valid {
		p.Mu().Unlock()
		return store.CodeAttestation{}, false
	}
	seKey, version, token, nodeKey := p.AttestationResult.PublicKey, p.Version, p.APNsDeviceToken, p.PublicKey
	binary, _ := s.deps.NormalizeHash(p.AttestationResult.BinaryHash, "binary_hash")
	p.Mu().Unlock()
	binary = s.deps.ApplicationBinaryHash(p, seKey, binary)
	t := s.state
	t.mu.Lock()
	defer t.mu.Unlock()
	r, ok := t.attested[seKey]
	if !ok || seKey == "" || version == "" || token == "" || nodeKey == "" || binary == "" || r.binaryHash != binary || r.version != version || r.token != token || r.nodeKey != nodeKey || r.at.After(at) {
		return store.CodeAttestation{}, false
	}
	if at.After(r.coveredUntil) {
		r.coveredUntil = at
		t.attested[seKey] = r
	}
	return r.persisted(seKey), true
}

func (s *Manager) persistCodeCoverage(rows []store.CodeAttestation) {
	if len(rows) == 0 || s.state == nil {
		return
	}
	st, ok := s.deps.CoverageStore()
	if !ok {
		return
	} // no durable continuity on unsupported stores
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := st.AdvanceCodeAttestationCoverage(ctx, rows); err != nil {
		s.deps.Incr("code_attest.coverage_persist", []string{"outcome:error"})
		s.deps.Logger.Warn("code-attest: failed to persist process continuity coverage", "providers", len(rows))
	} else {
		s.deps.Incr("code_attest.coverage_persist", []string{"outcome:success"})
	}
}

func (s *Manager) SweepCoverage() {
	if s == nil || s.deps.Registry == nil {
		return
	}
	rows := []store.CodeAttestation{}
	s.deps.Registry.ForEachProvider(func(p *registry.Provider) {
		if r, ok := s.codeCoverageObservation(p, false); ok {
			rows = append(rows, r)
		}
	})
	s.persistCodeCoverage(rows)
}

func (s *Manager) StopCoverageForProvider(providerID string) {
	if s == nil || s.deps.Registry == nil {
		return
	}
	if r, ok := s.codeCoverageObservation(s.deps.Registry.GetProvider(providerID), true); ok {
		s.persistCodeCoverage([]store.CodeAttestation{r})
	}
}
