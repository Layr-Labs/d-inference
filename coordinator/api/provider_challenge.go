package api

import (
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/providercontrol/challenge"
)

// A verifier shares current dependencies, while each provider read loop creates
// its own Session and owns its start, delivery and context cancellation.
func (s *Server) newProviderChallengeVerifier() *challenge.Verifier {
	return challenge.New(challenge.Dependencies{
		Registry: func() challenge.Registry {
			if s.registry == nil {
				return nil
			}
			return s.registry
		},
		Logger: func() *slog.Logger { return s.logger },
		Counters: func() challenge.Counters {
			if s.metrics == nil {
				return nil
			}
			return s.metrics
		},
		Scheduler: func() challenge.Scheduler {
			if s.mdmScheduler == nil {
				return nil
			}
			return s.mdmScheduler
		},
		Skip:                    func() bool { return s.skipChallenge },
		Interval:                func() time.Duration { return s.challengeInterval },
		BinaryHashPolicy:        s.binaryHashPolicySnapshot,
		EnforceBinaryHash:       func() bool { return s.binaryHashEnforce },
		NormalizeHash:           normalizeSHA256Hex,
		ApplyRuntime:            s.applyChallengeRuntimePolicy,
		ApplyMinimumVersion:     s.applyChallengeMinVersionPolicy,
		MinimumVersion:          func() string { return s.minProviderVersion },
		DeriveReleaseTransition: s.deriveApprovedReleaseTransition,
		TryReuse:                s.tryTrustReuseFastSkip,
		AttachMDA:               s.newProviderVerifier().AttachCachedMDA,
		SendStatus:              s.sendTrustStatus,
		Incr:                    s.ddIncr, Emit: s.emit,
		CodeMetric:      s.codeAttestMetric,
		EvidenceOutcome: s.recordReleaseEvidenceOutcome,
	})
}
