package codeidentity

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// TryResumeApproved combines a genuine cached APNs proof (same SE identity,
// same exact APNs token — the process key MAY differ, since the provider mints
// a fresh ephemeral NodeKeyPair every process start) with CURRENT generation-
// bound application evidence (a fresh SE-signed challenge attesting this exact
// process key and approved binary) only to authorize a live encrypted resume
// challenge to the current process key. The cached proof must additionally
// have been EARNED by the same binary this process now runs, or by an APPROVED
// active predecessor of the current release (the exact approved-transition
// derivation) — a proof earned by a since-deactivated or unknown release falls
// through to a real APNs challenge under the durable floor (Codex 05:55Z P1).
// Decrypting that challenge is the sole possession proof for the new key; the
// persisted proof never grants code trust by itself. This is what lets a
// routine upgrade/restart re-attest over the live WebSocket instead of falling
// to a fresh APNs push behind the durable per-device floor while queued
// requests expire (Codex 05:33Z #1).
func (s *Manager) TryResumeApproved(
	ctx context.Context,
	providerID string,
	provider *registry.Provider,
) bool {
	evidence, ok := provider.ApplicationEvidenceSnapshot()
	if !ok || evidence.BinaryHash == "" || evidence.ProcessPublicKey == "" ||
		evidence.APNsToken == "" || evidence.PolicyGeneration == 0 {
		return false
	}
	snapshot := s.deps.ReleasePolicy()
	if snapshot == nil || !snapshot.RequiresCodeIdentity() ||
		snapshot.PolicyGeneration() != evidence.PolicyGeneration {
		return false
	}
	provider.Mu().Lock()
	nodeKey := provider.PublicKey
	provider.Mu().Unlock()
	if nodeKey == "" || evidence.ProcessPublicKey != nodeKey {
		return false
	}
	cachedBinaryHash, ok := s.state.reuseAttestationForTransition(
		evidence.SEPublicKey, evidence.APNsToken)
	if !ok {
		return false
	}
	// Bind the proof to the binary that earned it: same binary as the current
	// approved identity, or an APPROVED active predecessor of the current
	// release. Legacy identity-less records already failed above.
	if cachedBinaryHash != evidence.BinaryHash &&
		!snapshot.AllowsPredecessor(
			cachedBinaryHash,
			evidence.Platform, evidence.Backend, evidence.Version,
		) {
		return false
	}
	if !s.sendCodeIdentityResumeChallenge(
		ctx, providerID, provider, nodeKey,
		evidence.SEPublicKey, evidence.APNsToken,
	) {
		return false
	}
	s.deps.Metric("resume_sent_approved_release")
	s.deps.Logger.Info("code-attest: current approved release authorized a live process-key resume challenge")
	return true
}
