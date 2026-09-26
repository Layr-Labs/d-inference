package api

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/apns"
)

// APNs code-identity push diagnostics. Each push records what APNs did with it
// (code_attest.push{outcome}) and each accepted push later records whether the
// provider answered it (code_attest.push_reply{result}). Metric tags are closed
// buckets with no provider, device or token identifiers; the structured log
// line carries provider_id like the rest of the code-attest logs. None of this
// changes the send's error semantics or any attestation decision.

// sendCodeChallengeRecorded sends one push through the attestor seam and
// records its outcome. The returned error is the attestor's own.
func (s *Server) sendCodeChallengeRecorded(ctx context.Context, providerID, deviceToken, env, pubKey, nonceB64 string) error {
	var result apns.PushResult
	var err error
	if reporter, ok := s.codeAttestor.(apns.ResultReporter); ok {
		result, err = reporter.SendCodeChallengeResult(ctx, deviceToken, env, pubKey, nonceB64)
	} else {
		// An attestor that cannot describe the push: success means APNs
		// accepted it; any failure is indistinguishable from transport.
		err = s.codeAttestor.SendCodeChallenge(ctx, deviceToken, env, pubKey, nonceB64)
		if err == nil {
			result.StatusCode = 200
		} else {
			result.Transport = true
		}
	}
	outcome := result.Outcome()
	s.ddIncr("code_attest.push", []string{"outcome:" + outcome})
	s.metrics.IncCounter("code_attest_push_total", MetricLabel{"outcome", outcome})
	s.logger.Info("code-attest push outcome", "provider_id", providerID,
		"code_attest_push_outcome", outcome, "apns_status", result.StatusCode,
		"apns_reason", result.Reason, "apns_id_present", result.APNsIDPresent)
	return err
}

// recordCodeAttestPushReply records whether an APNs-accepted push was
// answered: "answered" when its nonce is consumed by a verified reply,
// "unanswered" when the loop re-pushes after the previous accepted push drew
// no verified reply. A late reply after an unanswered retry counts both.
func (s *Server) recordCodeAttestPushReply(providerID, result string) {
	s.ddIncr("code_attest.push_reply", []string{"result:" + result})
	s.metrics.IncCounter("code_attest_push_reply_total", MetricLabel{"result", result})
	s.logger.Info("code-attest push reply", "provider_id", providerID, "code_attest_push_reply", result)
}
