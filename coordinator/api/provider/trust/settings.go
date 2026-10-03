package trust

import (
	"crypto/subtle"
	"io"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/apns"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/profilesign"
)

func (s *Owner) SetProfileSigner(signer *profilesign.Signer) {
	s.profileSigner = signer
}

func (s *Owner) SetChallengeInterval(d time.Duration) {
	s.challengeInterval = d
}

func (s *Owner) SetSkipChallenge(skip bool) {
	s.skipChallenge = skip
}

func (s *Owner) SetAllowDuplicateProviderSerialsForTesting(allow bool) {
	s.allowDuplicateProviderSerials = allow
}

func (s *Owner) SetMDMClient(client *mdm.Client) {
	s.mdmClient = client
	if client != nil && s.mdmScheduler == nil {
		s.mdmScheduler = newMDMVerificationScheduler(s, s.mdmSchedulerConfig, mdmSchedulerDeps{})
	}
}

func (s *Owner) StartMDMScheduler() {
	if s.mdmScheduler != nil {
		s.mdmScheduler.Start()
	}
}

func (s *Owner) SetCodeAttestor(a apns.CodeIdentityAttestor) {
	s.codeAttestor = a
	s.registry.SetCodeAttestationConfigured(a != nil)
}

func (s *Owner) SetCodeAttestationDeadline(t time.Time) {
	s.registry.SetCodeAttestationDeadline(t)
}

func (s *Owner) SetMDMWebhookSecret(secret string) {
	s.mdmWebhookSecret = secret
}

func (s *Owner) HandleMDMWebhook(w http.ResponseWriter, r *http.Request) {
	if s.mdmWebhookSecret != "" && !s.mdmWebhookTokenValid(r) {
		s.logger.Warn("mdm webhook rejected: missing/invalid shared secret", "remote_addr", r.RemoteAddr)
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxMDMWebhookBodyBytes)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	s.logger.Debug("mdm webhook received", "body_size", len(body), "body_preview", string(body[:min(len(body), 500)]))
	if s.mdmClient != nil {
		s.mdmClient.HandleWebhook(body)
	}
	w.WriteHeader(http.StatusOK)
}

const maxMDMWebhookBodyBytes = 1 << 20

// mdmWebhookTokenValid accepts the configured secret in either supported slot.
func (s *Owner) mdmWebhookTokenValid(r *http.Request) bool {
	token := r.Header.Get("X-Webhook-Token")
	if token == "" {
		token = r.URL.Query().Get("token")
	}
	return token != "" && subtle.ConstantTimeCompare([]byte(token), []byte(s.mdmWebhookSecret)) == 1
}
