package codeidentity

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/apns"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Registry retains the authoritative live provider and routing operations.
type Registry interface {
	GetProvider(string) *registry.Provider
	ForEachProvider(func(*registry.Provider))
	ReconcileAttestedRuntimeCapabilities(string) error
	DrainQueuedRequestsForProviderWithReason(*registry.Provider, string)
}

// ReleasePolicy is one immutable snapshot captured for an admission decision.
// The caller must return a true nil interface when no snapshot is published.
type ReleasePolicy interface {
	RequiresCodeIdentity() bool
	PolicyGeneration() uint64
	AllowsPredecessor(fromHash, platform, backend, version string) bool
}

type ResumeSender func(string, protocol.CodeAttestationResumeChallenge) error

// Dependencies separate startup proof persistence from live coverage discovery.
// Registry and Logger are bound at construction; the API has no setters for them.
// ReleasePolicy and CoverageStore are evaluated at their existing read boundaries.
// ResumeSender defaults to the real provider WebSocket; other callbacks bind
// the caller's current metrics, measured identity and immutable release policy.
type Dependencies struct {
	Registry                  Registry
	Logger                    *slog.Logger
	NormalizeHash             func(string, string) (string, error)
	ApplicationBinaryHash     func(*registry.Provider, string, string) string
	ReleasePolicy             func() ReleasePolicy
	CoverageStore             func() (CoverageStore, bool)
	Incr                      func(string, []string)
	Metric                    func(string)
	ResumeSender              func() ResumeSender
	BeforeResumeIdentityCheck func()
	BeforeResumeFallbackAPNs  func()
}

// Manager owns the sole per-device proof, nonce, generation and push-budget
// ledger. Per-connection loops stop through their caller's context; coverage
// sweeps and disconnect observations are explicit lifecycle operations.
type Manager struct {
	state    *deviceState
	attestor apns.CodeIdentityAttestor
	deps     Dependencies
}

func New(cfg Config, deps Dependencies) *Manager {
	if deps.ResumeSender == nil {
		deps.ResumeSender = func() ResumeSender { return nil }
	}
	return &Manager{state: newConfiguredState(cfg), deps: deps}
}

func (s *Manager) SetAttestor(attestor apns.CodeIdentityAttestor) { s.attestor = attestor }
func (s *Manager) Enabled() bool                                  { return s != nil && s.attestor != nil }

func (s *Manager) ClearResumeChallenges(providerID string) {
	if s != nil && s.state != nil {
		s.state.clearResumeChallenges(providerID)
	}
}

// ReuseBasis and TransitionBinaryHash are read-only candidate observations.
// Neither grants trust: every reuse still needs an encrypted live challenge.
func (s *Manager) ReuseBasis(seKey, version, token, nodeKey string) string {
	return s.state.reuseAttestationBasis(seKey, version, token, nodeKey)
}
func (s *Manager) TransitionBinaryHash(seKey, token string) (string, bool) {
	return s.state.reuseAttestationForTransition(seKey, token)
}
