package coverage

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/releases"
	identityevidence "github.com/eigeninference/d-inference/coordinator/internal/provider/identity/evidence"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type codeAttestCoverageStore interface {
	AdvanceCodeAttestationCoverage(context.Context, []store.CodeAttestation) error
}

// Observation is authorized by an already verified connection, not by a
// heartbeat claiming a version/token. Capture the timestamp with the flags.
// Only final disconnect stamping may observe the just-offlined connection;
// periodic and shutdown sweeps must not extend coverage for offline providers.
func (s *Observer,

) CodeCoverageObservation(p *registry.Provider, allowOffline bool) (store.CodeAttestation, bool) {
	if p == nil || s.codeAttestThrottle == nil {
		return store.CodeAttestation{}, false
	}
	p.Mu().Lock()
	at := s.codeAttestThrottle.Now().Truncate(time.Microsecond)
	statusAllowed := p.Status == registry.StatusOnline || (allowOffline && p.Status == registry.StatusOffline)
	if !p.CodeAttested || !p.FreshCodeAttested || !statusAllowed || p.TrustLevel != registry.TrustHardware || p.AttestationResult == nil || !p.AttestationResult.Valid {
		p.Mu().Unlock()
		return store.CodeAttestation{}, false
	}
	seKey, version, token, nodeKey := p.AttestationResult.PublicKey, p.Version, p.APNsDeviceToken, p.PublicKey
	binary, _ := releases.NormalizeSHA256Hex(p.AttestationResult.BinaryHash, "binary_hash")
	p.Mu().Unlock()
	binary = identityevidence.BinaryHash(p, seKey, binary)
	return s.codeAttestThrottle.ObserveCoverage(seKey, version, token, nodeKey, binary, at)
}

func (s *Observer,

) PersistCodeCoverage(rows []store.CodeAttestation) {
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
		s.observation.Incr("code_attest.coverage_persist", []string{"outcome:error"})
		s.logger.Warn("code-attest: failed to persist process continuity coverage", "providers", len(rows))
	} else {
		s.observation.Incr("code_attest.coverage_persist", []string{"outcome:success"})
	}
}
