package trust

import (
	"context"
	"maps"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/api/releases"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

func (s *Owner) VerificationSubmitPriority(seKey, serial string) store.VerificationPriority {
	if s.trustReuseCache.hasFreshRecord(seKey, serial) {
		return store.VerificationPriorityRefresh
	}
	return store.VerificationPriorityFirstOrExpired
}

// applyChallengeRuntimePolicy first records the exact signed runtime identity,
// then applies the current manifest policy when one exists. Policy withdrawal
// keeps runtime gates closed without invalidating an unchanged process proof;
// any changed or omitted identity clears FreshCodeAttested independently.
func (s *Owner) applyChallengeRuntimePolicy(
	provider *registry.Provider,
	resp *protocol.AttestationResponseMessage,
) (bool, bool, []protocol.RuntimeMismatch) {
	manifest := s.releases.RuntimeManifest()
	policyActive := manifest != nil
	runtimeOK := false
	var mismatches []protocol.RuntimeMismatch
	if policyActive {
		runtimeOK, mismatches = s.releases.VerifyRuntimeHashesForBackend(
			provider.Backend, resp.TemplateHashes)
	}

	provider.Mu().Lock()
	runtimeIdentityChanged := !maps.EqualFunc(
		resp.TemplateHashes,
		provider.TemplateHashes,
		strings.EqualFold,
	)

	provider.RuntimeVerified = policyActive && runtimeOK
	provider.RuntimeManifestChecked = policyActive && runtimeOK
	provider.MetallibVerified = policyActive && runtimeOK &&
		releases.RuntimeManifestApprovesMetallib(manifest, resp.TemplateHashes)
	if !provider.RuntimeVerified ||
		!provider.MetallibVerified ||
		runtimeIdentityChanged {
		provider.RuntimeCapabilities = nil
	}
	if runtimeIdentityChanged {
		provider.FreshCodeAttested = false
	}
	provider.TemplateHashes = registry.CloneStringMap(resp.TemplateHashes)
	provider.Mu().Unlock()
	return policyActive, runtimeOK, mismatches
}

// applyChallengeMinVersionPolicy clears only policy-derived runtime state when
// the coordinator temporarily raises its version floor. The unchanged process
// proof remains valid and can promote capabilities again if policy rolls back.
func (s *Owner) applyChallengeMinVersionPolicy(
	provider *registry.Provider,
) (string, bool) {
	provider.Mu().Lock()
	defer provider.Mu().Unlock()
	version := provider.Version
	if !s.BelowMinProviderVersion(version) {
		return version, true
	}
	provider.RuntimeVerified = false
	provider.RuntimeManifestChecked = false
	provider.MetallibVerified = false
	provider.RuntimeCapabilities = nil
	return version, false
}

// handleTransientChallengeFailure records a transient challenge failure
// (timeout / no response) and, once a provider has missed too many consecutive
// challenges, force-closes its WebSocket so it must reconnect and re-register.
//
// A provider whose outbound path is wedged keeps heartbeating (so the stale
// sweeper never evicts it) while every challenge times out, pinning it
// hardware/untrusted forever. MarkUntrustedTransient alone cannot recover it
// because recovery requires a passing challenge, which requires a working
// outbound path. Cycling the connection forces a clean re-registration.
func (s *Owner) handleTransientChallengeFailure(conn *websocket.Conn, providerID, reason string) {
	failures := s.handleChallengeFailure(providerID, reason)
	if conn == nil || failures < MaxConsecutiveChallengeTimeoutsBeforeReconnect {
		return
	}
	s.logger.Warn("provider exceeded consecutive challenge timeouts — forcing reconnect",
		"provider_id", providerID,
		"consecutive_failures", failures,
		"reason", reason,
	)
	s.observation.Incr("attestation.force_reconnect", []string{"reason:" + reason})
	if s.observation.Metrics() != nil {
		s.observation.Metrics().IncCounter("attestation_force_reconnect_total", observation.MetricLabel{Name: "reason", Value: reason})
	}
	// Closing the conn unblocks providerReadLoop's conn.Read, which cancels the
	// loop context (stopping this challenge loop) and runs registry.Disconnect.
	_ = conn.Close(websocket.StatusPolicyViolation, "attestation unresponsive — reconnect required")
}

// handleChallengeFailure records a failed challenge and marks the provider
// as untrusted if the failure threshold is reached. It returns the running
// count of consecutive failures.
func (s *Owner) handleChallengeFailure(providerID string, reason string) int {
	transient := reason == "timeout" || reason == "no response"
	failures := s.registry.RecordChallengeFailure(providerID, transient)
	s.observation.Incr("attestation.challenges", []string{"outcome:failed"})
	s.logger.Warn("attestation challenge failed",
		"provider_id", providerID,
		"reason", reason,
		"consecutive_failures", failures,
	)

	severity := protocol.SeverityWarn
	if failures >= registry.MaxFailedChallenges {
		severity = protocol.SeverityError
		if transient {
			// Missed-challenge timeouts (sleep / network blip) are recoverable:
			// keep challenging and let a later passing challenge restore the
			// provider without requiring a reconnect.
			s.registry.MarkUntrustedTransient(providerID)
		} else {
			s.registry.MarkUntrusted(providerID)
		}
		if p := s.registry.GetProvider(providerID); p != nil {
			s.sendTrustStatus(p, p.TrustLevel, string(registry.StatusUntrusted), reason)
		}
	}
	s.observation.Emit(context.Background(), severity, protocol.KindAttestationFailure,
		"attestation challenge failed",
		map[string]any{
			"provider_id":     providerID,
			"reason":          reason,
			"reconnect_count": failures,
		})
	if s.observation.Metrics() != nil {
		s.observation.Metrics().IncCounter("attestation_failures_total",
			observation.MetricLabel{Name: "reason", Value: reason},
		)
	}
	s.observation.Incr("attestation.failures", []string{"reason:" + reason})
	return failures
}
