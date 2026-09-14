package api

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/releasepolicy"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Server) releasePolicyDependencies() releasepolicy.Dependencies {
	return releasepolicy.Dependencies{
		Store: func() releasepolicy.Store { return s.store },
		Registry: func() releasepolicy.Registry {
			if s.registry == nil {
				return nil
			}
			return s.registry
		},
		Logger:         func() *slog.Logger { return s.logger },
		MinimumVersion: func() string { return s.minProviderVersion }, Incr: s.ddIncr,
	}
}

// The zero Server value retains its unconfigured policy. NewServer explicitly
// installs its historical empty runtime manifest before serving starts.
func (s *Server) releasePolicyOwner() *releasepolicy.Manager {
	s.releasePolicyOnce.Do(func() { s.releasePolicy = releasepolicy.New(s.releasePolicyDependencies()) })
	return s.releasePolicy
}

type RuntimeManifest = releasepolicy.RuntimeManifest

func NewRuntimeManifest() *RuntimeManifest { return releasepolicy.NewRuntimeManifest() }
func (s *Server) SetKnownBinaryHashes(hashes []string) {
	s.releasePolicyOwner().SetKnownBinaryHashes(hashes)
}
func (s *Server) AddKnownBinaryHashes(hashes []string) {
	s.releasePolicyOwner().AddKnownBinaryHashes(hashes)
}
func (s *Server) SyncBinaryHashes() error               { return s.releasePolicyOwner().SyncBinaryHashes() }
func (s *Server) SyncRuntimeManifest() error            { return s.releasePolicyOwner().SyncRuntimeManifest() }
func (s *Server) SetRuntimeManifest(m *RuntimeManifest) { s.releasePolicyOwner().SetRuntimeManifest(m) }
func (s *Server) binaryHashPolicySnapshot() (bool, map[string]bool) {
	return s.releasePolicyOwner().BinaryHashPolicySnapshot()
}
func (s *Server) convergeReleasePolicyWithCommittedRelease(r *store.Release, e error) {
	s.releasePolicyOwner().ConvergeCommittedRelease(r, e)
}
func (s *Server) convergeReleasePolicyWithCommittedDeactivation(v, p string, e error) {
	s.releasePolicyOwner().ConvergeCommittedDeactivation(v, p, e)
}
func (s *Server) convergeRuntimeManifestWithCommittedRelease(r *store.Release, e error) {
	s.releasePolicyOwner().ConvergeCommittedRuntimeRelease(r, e)
}
func (s *Server) convergeRuntimeManifestWithCommittedDeactivation(v, p string, e error) {
	s.releasePolicyOwner().ConvergeCommittedRuntimeDeactivation(v, p, e)
}

func (s *Server) deriveApprovedReleaseTransition(p *registry.Provider, r *protocol.AttestationResponseMessage, trusted bool) (approvedReleaseTransitionFact, registry.ApplicationEvidence, bool) {
	return s.releasePolicyOwner().DeriveApprovedTransition(p, r, trusted)
}
func (s *Server) applyChallengeRuntimePolicy(p *registry.Provider, r *protocol.AttestationResponseMessage) (bool, bool, []protocol.RuntimeMismatch) {
	return s.releasePolicyOwner().ApplyChallengeRuntimePolicy(p, r)
}
func (s *Server) applyChallengeMinVersionPolicy(p *registry.Provider) (string, bool) {
	return s.releasePolicyOwner().ApplyChallengeMinVersionPolicy(p)
}
func (s *Server) verifyRuntimeHashesForBackend(b, p, r string, t map[string]string) (bool, []protocol.RuntimeMismatch) {
	return s.releasePolicyOwner().VerifyRuntimeHashesForBackend(b, p, r, t)
}

func runtimeManifestApprovesMetallib(m *RuntimeManifest, t map[string]string) bool {
	return releasepolicy.RuntimeManifestApprovesMetallib(m, t)
}
func sortedTemplateHashes(t map[string]bool) []string { return releasepolicy.SortedTemplateHashes(t) }

func semverLess(a, b string) bool                    { return releasepolicy.VersionLess(a, b) }
func normalizeSHA256Hex(v, f string) (string, error) { return releasepolicy.NormalizeSHA256Hex(v, f) }

func (s *Server) recordReleaseEvidenceOutcome(outcome string) {
	s.releasePolicyOwner().RecordEvidenceOutcome(outcome)
}
