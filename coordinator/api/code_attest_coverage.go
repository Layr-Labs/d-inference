package api

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// This is a same-process continuity bound, never a new lifetime for an APNs
// proof. Changed process keys and release transitions still need a recent proof.
const codeAttestContinuityGap = 120 * time.Second

type codeAttestCoverageStore interface {
	AdvanceCodeAttestationCoverage(context.Context, []store.CodeAttestation) error
}

func (r codeAttestRecord) recent(now time.Time, window time.Duration) bool {
	age := now.Sub(r.at)
	return age >= -clockSkewTolerance && age < window
}

func (r codeAttestRecord) continuous(now time.Time) bool {
	if r.binaryHash == "" || r.nodeKey == "" || r.token == "" || r.coveredUntil.IsZero() || r.coveredUntil.Before(r.at) {
		return false
	}
	gap := now.Sub(r.coveredUntil)
	return gap >= 0 && gap <= codeAttestContinuityGap
}

func (r codeAttestRecord) persisted(seKey string) store.CodeAttestation {
	out := store.CodeAttestation{SEPubKey: seKey, Version: r.version, AttestedAt: r.at,
		APNsToken: r.token, NodePublicKey: r.nodeKey, BinaryHash: r.binaryHash}
	if !r.coveredUntil.IsZero() {
		until := r.coveredUntil
		out.ContinuousCoverageUntil = &until
	}
	return out
}

// Observation is authorized by an already verified connection, not by a
// heartbeat claiming a version/token. Capture the timestamp with the flags.
// Only final disconnect stamping may observe the just-offlined connection;
// periodic and shutdown sweeps must not extend coverage for offline providers.
func (s *Server) codeCoverageObservation(p *registry.Provider, allowOffline bool) (store.CodeAttestation, bool) {
	if p == nil || s.codeAttestThrottle == nil {
		return store.CodeAttestation{}, false
	}
	p.Mu().Lock()
	at := s.codeAttestThrottle.now().Truncate(time.Microsecond)
	statusAllowed := p.Status == registry.StatusOnline || (allowOffline && p.Status == registry.StatusOffline)
	if !p.CodeAttested || !p.FreshCodeAttested || !statusAllowed || p.TrustLevel != registry.TrustHardware || p.AttestationResult == nil || !p.AttestationResult.Valid {
		p.Mu().Unlock()
		return store.CodeAttestation{}, false
	}
	seKey, version, token, nodeKey := p.AttestationResult.PublicKey, p.Version, p.APNsDeviceToken, p.PublicKey
	binary, _ := normalizeSHA256Hex(p.AttestationResult.BinaryHash, "binary_hash")
	p.Mu().Unlock()
	binary = providerApplicationBinaryHash(p, seKey, binary)
	t := s.codeAttestThrottle
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

func (s *Server) persistCodeCoverage(rows []store.CodeAttestation) {
	if len(rows) == 0 || s.codeAttestThrottle == nil {
		return
	}
	st, ok := store.As[codeAttestCoverageStore](s.store)
	if !ok {
		return
	} // no durable continuity on unsupported stores
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := st.AdvanceCodeAttestationCoverage(ctx, rows); err != nil {
		s.ddIncr("code_attest.coverage_persist", []string{"outcome:error"})
		s.logger.Warn("code-attest: failed to persist process continuity coverage", "providers", len(rows))
	} else {
		s.ddIncr("code_attest.coverage_persist", []string{"outcome:success"})
	}
}

func (s *Server) sweepCodeAttestCoverage() {
	if s == nil || s.registry == nil {
		return
	}
	rows := []store.CodeAttestation{}
	s.registry.ForEachProvider(func(p *registry.Provider) {
		if r, ok := s.codeCoverageObservation(p, false); ok {
			rows = append(rows, r)
		}
	})
	s.persistCodeCoverage(rows)
}

func (s *Server) stopCodeAttestCoverageForProvider(providerID string) {
	if s == nil || s.registry == nil {
		return
	}
	if r, ok := s.codeCoverageObservation(s.registry.GetProvider(providerID), true); ok {
		s.persistCodeCoverage([]store.CodeAttestation{r})
	}
}
