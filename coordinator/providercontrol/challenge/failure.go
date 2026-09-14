package challenge

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/telemetry/metrics"
	"nhooyr.io/websocket"
)

// TransientFailure records a transient challenge failure
// (timeout / no response) and, once a provider has missed too many consecutive
// challenges, force-closes its WebSocket so it must reconnect and re-register.
//
// A provider whose outbound path is wedged keeps heartbeating (so the stale
// sweeper never evicts it) while every challenge times out, pinning it
// hardware/untrusted forever. MarkUntrustedTransient alone cannot recover it
// because recovery requires a passing challenge, which requires a working
// outbound path. Cycling the connection forces a clean re-registration.
func (s *Verifier) TransientFailure(conn *websocket.Conn, providerID, reason string) {
	failures := s.RecordFailure(providerID, reason)
	if conn == nil || failures < MaxConsecutiveTimeoutsBeforeReconnect {
		return
	}
	s.deps.Logger().Warn("provider exceeded consecutive challenge timeouts — forcing reconnect",
		"provider_id", providerID,
		"consecutive_failures", failures,
		"reason", reason,
	)
	s.deps.Incr("attestation.force_reconnect", []string{"reason:" + reason})
	if s.deps.Counters() != nil {
		s.deps.Counters().IncCounter("attestation_force_reconnect_total", metrics.Label{Name: "reason", Value: reason})
	}
	// Closing the conn unblocks providerReadLoop's conn.Read, which cancels the
	// loop context (stopping this challenge loop) and runs registry.Disconnect.
	_ = conn.Close(websocket.StatusPolicyViolation, "attestation unresponsive — reconnect required")
}

// RecordFailure records a failed challenge and marks the provider
// as untrusted if the failure threshold is reached. It returns the running
// count of consecutive failures.
func (s *Verifier) RecordFailure(providerID string, reason string) int {
	transient := reason == "timeout" || reason == "no response"
	failures := s.deps.Registry().RecordChallengeFailure(providerID, transient)
	s.deps.Incr("attestation.challenges", []string{"outcome:failed"})
	s.deps.Logger().Warn("attestation challenge failed",
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
			s.deps.Registry().MarkUntrustedTransient(providerID)
		} else {
			s.deps.Registry().MarkUntrusted(providerID)
		}
		if p := s.deps.Registry().GetProvider(providerID); p != nil {
			s.deps.SendStatus(p, p.TrustLevel, string(registry.StatusUntrusted), reason)
		}
	}
	s.deps.Emit(context.Background(), severity, protocol.KindAttestationFailure,
		"attestation challenge failed",
		map[string]any{
			"provider_id":     providerID,
			"reason":          reason,
			"reconnect_count": failures,
		})
	if s.deps.Counters() != nil {
		s.deps.Counters().IncCounter("attestation_failures_total",
			metrics.Label{Name: "reason", Value: reason},
		)
	}
	s.deps.Incr("attestation.failures", []string{"reason:" + reason})
	return failures
}
