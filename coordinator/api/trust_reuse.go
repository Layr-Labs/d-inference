package api

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/trustreuse"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"time"
)

// approvedReleaseTransitionFact is constructed only from the current runtime
// release policy after registration-bound signature verification.
type approvedReleaseTransitionFact = trustreuse.ReleaseTransition

func (s *Server) trustReuseDependencies() trustreuse.Dependencies {
	return trustreuse.Dependencies{
		Registry: s.registry, Logger: s.logger,
		MDMConfigured:      func() bool { return s.mdmClient != nil },
		NormalizeHash:      normalizeSHA256Hex,
		SendStatus:         s.sendTrustStatus,
		RecordDecision:     s.trustReuseMetric,
		AfterCoverageSweep: s.sweepCodeAttestCoverage,
	}
}

// InitializeTrustReuseJournal validates the local journal before startup.
func (s *Server) InitializeTrustReuseJournal() error {
	if s == nil {
		return nil
	}
	return s.trustReuse.InitializeJournal()
}

// SeedTrustReuseCache binds the startup store, replays durable revocations, and
// seeds reusable evidence before the HTTP listener starts.
func (s *Server) SeedTrustReuseCache(ctx context.Context) error {
	if s == nil {
		return nil
	}
	return s.trustReuse.Seed(ctx, s.store)
}

func (s *Server) trustSafetyStatus() (bool, string) {
	if s == nil {
		return false, ""
	}
	return s.trustReuse.SafetyStatus()
}

func (s *Server) recordTrustReuse(provider *registry.Provider, seKey, serial, binaryHash string, sipEnabled, secureBootFull bool, udid string) bool {
	if s == nil {
		return false
	}
	return s.trustReuse.RecordVerified(provider, seKey, serial, binaryHash, sipEnabled, secureBootFull, udid)
}

func (s *Server) recordLateTrustReuse(provider *registry.Provider, seKey, serial, binaryHash string, sipEnabled, secureBootFull bool, udid string) bool {
	if s == nil {
		return false
	}
	return s.trustReuse.RecordLate(provider, seKey, serial, binaryHash, sipEnabled, secureBootFull, udid)
}

func (s *Server) tryTrustReuseFastSkip(providerID string, provider *registry.Provider, resp *protocol.AttestationResponseMessage, statusFieldsTrusted bool, facts ...approvedReleaseTransitionFact) bool {
	if s == nil {
		return false
	}
	return s.trustReuse.TryReuse(providerID, provider, resp, statusFieldsTrusted, facts...)
}

func (s *Server) trustReuseMetric(decision trustreuse.Decision, reason trustreuse.Reason) {
	decisionLabel := string(decision)
	if decisionLabel == "" {
		decisionLabel = "rejected"
	}
	s.ddIncr("trust_reuse.decisions", []string{
		"decision:" + decisionLabel,
		"reason:" + string(reason),
	})
	if s.metrics != nil {
		s.metrics.IncCounter("trust_reuse_decisions_total",
			MetricLabel{"decision", decisionLabel},
			MetricLabel{"reason", string(reason)})
	}
}

// providerApplicationBinaryHash resolves the binary measured for this
// connection. A registration hash is authoritative when present. Hashless
// registrations may use fresh application evidence only while it remains
// installed and bound to both the verified SE identity and this provider
// process's current public key.
func providerApplicationBinaryHash(provider *registry.Provider, seKey, registrationHash string) string {
	if registrationHash != "" {
		return registrationHash
	}
	if provider == nil || seKey == "" {
		return ""
	}

	provider.Mu().Lock()
	defer provider.Mu().Unlock()
	evidence := provider.ApplicationEvidence
	if evidence.EvidenceGeneration == 0 || evidence.SEPublicKey != seKey ||
		provider.PublicKey == "" || evidence.ProcessPublicKey != provider.PublicKey {
		return ""
	}
	return evidence.BinaryHash
}

// Shared application-evidence callers retain the same device-coverage conventions.
const clockSkewTolerance = trustreuse.ClockSkewTolerance

func coverageFromStore(until *time.Time) time.Time { return trustreuse.CoverageFromStore(until) }
