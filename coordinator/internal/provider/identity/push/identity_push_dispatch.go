package push

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// codeAttestMetric records a code-identity attestation outcome to both Datadog
// (s.ddIncr) and the in-process registry exposed at /v1/admin/metrics, so the
// APNs code-attest funnel (push_sent → attested vs timeout/verify_failed/no_token)
// is measurable per cohort. Outcomes: no_token, reused, push_sent,
// push_send_failed, attested, nonce_mismatch, verify_failed, timeout,
// max_attempts (fast attempts spent; the loop continues slowly), slow_retry,
// rearm_token_arrived, rearm_token_changed (W5 Fix 2 heartbeat re-arm).
// Metadata only — no provider identifiers in the metric.
func (s *Dispatcher,

) CodeAttestMetric(outcome string) {
	s.observation.Incr("code_attest", []string{"outcome:" + outcome})
	s.observation.Metrics().IncCounter("code_attest_total", observation.MetricLabel{Name: "outcome", Value: outcome})
}

func (s *Dispatcher,

) SendCodeIdentityChallengeForReservation(
	ctx context.Context,
	provider *registry.Provider,
	sePubKey, deviceToken, pubKey string,
	loopGeneration uint64,
) bool {
	if s.codeAttestor == nil || provider == nil {
		return false
	}
	provider.Mu().Lock()
	currentToken := provider.APNsDeviceToken
	env := provider.APNsEnvironment
	currentPubKey := provider.PublicKey
	var currentSEPubKey string
	if provider.AttestationResult != nil {
		currentSEPubKey = provider.AttestationResult.PublicKey
	}
	provider.Mu().Unlock()

	if deviceToken == "" || pubKey == "" || sePubKey == "" ||
		currentToken != deviceToken ||
		currentPubKey != pubKey ||
		currentSEPubKey != sePubKey ||
		!s.codeAttestThrottle.LoopCurrentForToken(
			sePubKey, deviceToken, loopGeneration,
		) {
		s.logger.Warn("code-attest skipped: reserved push identity changed")
		return false
	}

	nonceBytes := make([]byte, 32)
	if _, err := rand.Read(nonceBytes); err != nil {
		s.logger.Error("code-attest nonce generation failed", "error", err)
		return false
	}
	nonceB64 := base64.StdEncoding.EncodeToString(nonceBytes)

	// Record the token + process key used for E_K(nonce). A reply landing on a
	// later connection is accepted only when both identities still match.
	s.codeAttestThrottle.RecordChallengeForIdentity(
		sePubKey, nonceB64, deviceToken, pubKey)

	sendCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	err := s.sendCodeChallengeRecorded(sendCtx, provider.ID, deviceToken, env, pubKey, nonceB64)
	cancel()
	if err != nil {
		// The push never went out — drop the outstanding challenge so no stale
		// reply for this nonce can attest.
		s.codeAttestThrottle.ClearChallengeIf(sePubKey, nonceB64)
		s.CodeAttestMetric("push_send_failed")
		s.logger.Warn("code-attest push send failed", "error", err)
		return false
	}
	s.CodeAttestMetric("push_sent")
	s.codeAttestThrottle.MarkChallengeAccepted(sePubKey, nonceB64, loopGeneration)
	// No blocking wait: the reply is verified in HandleCodeAttestationResponse on
	// whichever live connection it lands.
	return true
}
