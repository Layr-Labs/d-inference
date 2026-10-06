package trust

import (
	"crypto/subtle"
	"io"
	"net/http"
	"time"

	verification "github.com/eigeninference/d-inference/coordinator/internal/provider/verification"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/profilesign"
)

func (s *Owner) SetProfileSigner(signer *profilesign.Signer) {
	s.profileSigner = signer
}

func (s *Owner) SetChallengeInterval(d time.Duration) {
	s.challengeSettings.
		Interval = d
}

func (s *Owner) SetSkipChallenge(skip bool) {
	s.challengeSettings.
		Skip = skip
}

func (s *Owner) SetAllowDuplicateProviderSerialsForTesting(allow bool) {
	s.allowDuplicateProviderSerials = allow
}

func (s *Owner) SetMDMClient(client *mdm.Client) {
	s.verificationBackend.Client = client
	if client != nil && s.verificationBackend.Scheduler == nil {
		s.verificationBackend.Scheduler = s.NewVerificationScheduler(s.mdmSchedulerConfig, verification.Dependencies{
			LegacyMDMAllowed: s.LegacyMDM.ProviderAllowed,
		})
	}
}

func (s *Owner) StartMDMScheduler() {
	if s.verificationBackend.
		Scheduler !=
		nil {
		s.verificationBackend.
			Scheduler.
			Start()
	}
}

func (s *Owner) SetCodeAttestationDeadline(t time.Time) {
	s.registry.SetCodeAttestationDeadline(t)
}

func (s *Owner) SetMDMWebhookSecret(secret string) {
	s.mdmWebhookSecret = secret
}

func (s *Owner) HandleMDMWebhook(w http.ResponseWriter, r *http.Request) {
	if s.mdmWebhookSecret != "" && !s.mdmWebhookTokenValid(r) {
		s.logger.Warn("mdm webhook rejected: missing/invalid shared secret")
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxMDMWebhookBodyBytes)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	s.logger.Debug("mdm webhook received", "body_size", len(body))
	if s.verificationBackend.
		Client !=
		nil {
		s.verificationBackend.
			Client.
			HandleWebhook(body)
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
