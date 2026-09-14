package api

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/providercontrol/verification"
)

// Verification reads current API resources; connection and scheduler lifecycle
// stays outside the verifier. Bare-server fixtures retain true nil resources.
func (s *Server) newProviderVerifier() *verification.Verifier {
	return verification.New(verification.Dependencies{
		Registry: func() verification.Registry {
			if s.registry == nil {
				return nil
			}
			return s.registry
		},
		Store: func() verification.Store {
			if s.store == nil {
				return nil
			}
			return s.store
		},
		MDM: func() verification.MDM {
			if s.mdmClient == nil {
				return nil
			}
			return s.mdmClient
		},
		Scheduler: func() verification.Scheduler {
			if s.mdmScheduler == nil {
				return nil
			}
			return s.mdmScheduler
		},
		Logger:                func() *slog.Logger { return s.logger },
		BinaryHashPolicy:      s.binaryHashPolicySnapshot,
		EnforceBinaryHash:     func() bool { return s.binaryHashEnforce },
		AllowDuplicateSerials: func() bool { return s.allowDuplicateProviderSerials },
		NormalizeHash:         normalizeSHA256Hex,
		VersionLess:           semverLess,
		ApplicationBinaryHash: providerApplicationBinaryHash,
		RecordTrustReuse:      s.recordTrustReuse,
		SendStatus:            s.sendTrustStatus,
		Incr:                  s.ddIncr,
	})
}
