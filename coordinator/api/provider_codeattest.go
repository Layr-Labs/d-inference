package api

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/codeidentity"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Server) codeIdentityDependencies() codeidentity.Dependencies {
	return codeidentity.Dependencies{
		Registry: s.registry, Logger: s.logger, NormalizeHash: normalizeSHA256Hex,
		ApplicationBinaryHash: providerApplicationBinaryHash,
		ReleasePolicy: func() codeidentity.ReleasePolicy {
			snapshot := s.releaseTrustPolicy.Load()
			if snapshot == nil {
				return nil
			}
			return snapshot
		},
		CoverageStore: func() (codeidentity.CoverageStore, bool) {
			return store.As[codeidentity.CoverageStore](s.store)
		},
		Incr: s.ddIncr, Metric: s.codeAttestMetric,
	}
}

func (p *releaseTrustPolicySnapshot) RequiresCodeIdentity() bool { return p.Required }
func (p *releaseTrustPolicySnapshot) PolicyGeneration() uint64   { return p.Generation }
func (p *releaseTrustPolicySnapshot) AllowsPredecessor(fromHash, platform, backend, version string) bool {
	return approvedTransitionPredecessor(p, fromHash, platform, backend, version)
}

// SeedCodeAttestCache binds the startup proof store and restores proofs/budgets.
func (s *Server) SeedCodeAttestCache(ctx context.Context) {
	if s != nil {
		s.codeIdentity.Seed(ctx, s.store)
	}
}

func (s *Server) codeAttestLoop(ctx context.Context, id string, p *registry.Provider) {
	s.codeIdentity.Loop(ctx, id, p)
}
func (s *Server) tryCrossVersionReuse(ctx context.Context, id string, p *registry.Provider) bool {
	return s.codeIdentity.TryResumeApproved(ctx, id, p)
}
func (s *Server) maybeRearmCodeAttest(ctx context.Context, id string, p *registry.Provider, hb *protocol.HeartbeatMessage) {
	s.codeIdentity.Rearm(ctx, id, p, hb)
}
func (s *Server) handleCodeAttestationResponse(id string, p *registry.Provider, message *protocol.CodeAttestationResponseMessage) {
	s.codeIdentity.HandleResponse(id, p, message)
}
func (s *Server) sweepCodeAttestCoverage() {
	if s != nil {
		s.codeIdentity.SweepCoverage()
	}
}
func (s *Server) stopCodeAttestCoverageForProvider(id string) {
	if s != nil {
		s.codeIdentity.StopCoverageForProvider(id)
	}
}

// codeAttestMetric records a code-identity attestation outcome to both Datadog
// (s.ddIncr) and the in-process registry exposed at /v1/admin/metrics, so the
// APNs code-attest funnel (push_sent → attested vs timeout/verify_failed/no_token)
// is measurable per cohort. Outcomes: no_token, reused, push_sent,
// push_send_failed, attested, nonce_mismatch, verify_failed, timeout,
// max_attempts, rearm_token_arrived, rearm_token_changed (W5 Fix 2 heartbeat
// re-arm). Metadata only — no provider identifiers in the metric.
func (s *Server) codeAttestMetric(outcome string) {
	s.ddIncr("code_attest", []string{"outcome:" + outcome})
	s.metrics.IncCounter("code_attest_total", MetricLabel{Name: "outcome", Value: outcome})
}

// approvedTransitionPredecessor reports whether fromHash names an ACTIVE
// release row that the current release identity (platform/backend/version) may
// transition from. This is the single approved-transition derivation — the
// same per-candidate rule deriveApprovedReleaseTransition applies when
// building ApprovedFromBinaryHashes: same platform, backend-compatible (a
// legacy empty row backend matches any), and non-downgrade (the current
// version is not below the predecessor's). A hash absent from the ACTIVE
// inventory — e.g. a deactivated release — is never an approved predecessor.
func approvedTransitionPredecessor(
	snapshot *releaseTrustPolicySnapshot,
	fromHash, platform, backend, version string,
) bool {
	if snapshot == nil || fromHash == "" || platform == "" {
		return false
	}
	for _, candidate := range snapshot.ByBinaryHash[fromHash] {
		if candidate.Platform == platform &&
			(candidate.Backend == backend || candidate.Backend == "") &&
			!semverLess(version, candidate.Version) {
			return true
		}
	}
	return false
}
