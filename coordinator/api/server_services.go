package api

import (
	_ "embed"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/apns"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/datadog"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/payments/baserewards"
	"github.com/eigeninference/d-inference/coordinator/profilesign"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/telemetry"
)

// SetRateLimiter configures the per-account rate limiter applied to
// consumer inference endpoints. Pass nil to disable.
func (s *Server) SetRateLimiter(rl *ratelimit.Limiter) {
	s.access.SetRateLimiter(rl)
}

// SetFinancialRateLimiter configures a stricter per-account limiter for
// balance-mutating endpoints. Pass nil to disable.
func (s *Server) SetFinancialRateLimiter(rl *ratelimit.Limiter) {
	s.access.SetFinancialRateLimiter(rl)
}

// SetServiceRateLimiter configures the elevated limiter used for service-role
// accounts (e.g. OpenRouter). Pass nil to let service accounts bypass limits.
func (s *Server) SetServiceRateLimiter(rl *ratelimit.Limiter) {
	s.access.SetServiceRateLimiter(rl)
}

// SetAdminKey configures the admin API key for admin-only endpoints.
func (s *Server) SetAdminKey(key string) {
	s.access.SetAdminKey(key)
}

// SetMinProviderVersion sets the minimum provider version for routing.
func (s *Server) SetMinProviderVersion(v string) {
	s.trust.SetMinProviderVersion(v)
	s.accounts.SetMinProviderVersion(s.trust.MinProviderVersion())
}

// SetBaseURL sets the coordinator's public URL (used to template install.sh).
// Pass the canonical origin with no trailing slash, e.g. "https://api.darkbloom.dev".
// If unset, the install.sh handler derives a URL from the request's Host header.
func (s *Server) SetBaseURL(url string) {
	s.baseURL = strings.TrimRight(url, "/")
}

// SetR2CDNURL sets the public R2 bucket URL that install.sh substitutes as
// the model/template/release download origin. If unset, install.sh keeps the
// placeholder — providers will fail to pull artifacts, making the misconfig
// loud instead of silent.
func (s *Server) SetR2CDNURL(url string) {
	s.releases.SetR2CDNURL(url)
}

// SetEmitter wires the coordinator-side telemetry emitter. Call once at boot.
func (s *Server) SetEmitter(e *telemetry.Emitter) {
	s.observation.SetEmitter(e)
}

// SetDatadog wires the Datadog client for DogStatsD metrics and Logs API forwarding.
func (s *Server) SetDatadog(dd *datadog.Client) {
	s.observation.SetDatadog(dd)
}

// Datadog returns the Datadog client (or nil). Exposed so main.go and the
// telemetry emitter can share the same client.
func (s *Server) Datadog() *datadog.Client {
	return s.observation.Datadog()
}

// Metrics returns the in-process metrics registry so cmd/coordinator can
// expose it to the telemetry emitter and other integrations.
func (s *Server) Metrics() *observation.Metrics {
	return s.observation.Metrics()
}

// SetProfileSigner configures the CMS signing identity used to sign the
// enrollment .mobileconfig served by /v1/enroll. When unset (nil), profiles are
// served unsigned (the historical behaviour).
func (s *Server) SetProfileSigner(signer *profilesign.Signer) { s.trust.SetProfileSigner(signer) }

// SetBilling configures the billing service for multi-chain payments and referrals.
func (s *Server) SetBilling(svc *billing.Service) {
	s.billing = svc
	s.inference.SetBilling(svc)
	s.billingHTTP.SetService(svc)
	s.payouts.SetService(svc)
	s.erasure.SetBilling(svc)
}

func (s *Server) Billing() *billing.Service {
	return s.billing
}

// SetBaseRewards configures the provider base-rewards engine (off unless the
// EIGENINFERENCE_BASE_REWARDS flag is set; nil = disabled).
func (s *Server) SetBaseRewards(e *baserewards.Engine) {
	s.baseRewards = e
	s.billingHTTP.SetBaseRewards(e)
}

// BaseRewards returns the base-rewards engine, or nil when disabled.
func (s *Server) BaseRewards() *baserewards.Engine {
	return s.baseRewards
}

func (s *Server) SetChallengeInterval(d time.Duration) { s.trust.SetChallengeInterval(d) }

func (s *Server) SetSkipChallenge(skip bool) { s.trust.SetSkipChallenge(skip) }

// SetAllowDuplicateProviderSerialsForTesting lets the in-process E2E testbed
// emulate multiple physical providers on one Mac. Production never calls it.
func (s *Server) SetAllowDuplicateProviderSerialsForTesting(allow bool) {
	s.trust.SetAllowDuplicateProviderSerialsForTesting(allow)
}

// SetPrivyAuth configures Privy JWT authentication for consumer endpoints.
func (s *Server) SetPrivyAuth(pa *auth.PrivyAuth) {
	s.access.SetPrivyAuth(pa)
}

// SetAdminEmails configures which Privy accounts have admin access.
func (s *Server) SetAdminEmails(emails []string) { s.access.SetAdminEmails(emails) }

// SetMDMClient configures the MicroMDM client for provider verification.
// When set, providers are verified against MDM on registration.
func (s *Server) SetMDMClient(client *mdm.Client) { s.trust.SetMDMClient(client) }

// StartMDMScheduler starts the single durable dispatcher and fixed worker pool.
func (s *Server) StartMDMScheduler() { s.trust.StartMDMScheduler() }

// SetCodeAttestor wires the APNs code-identity attestor (v0.6.0). When set, the
// coordinator issues code-identity challenges and measures which providers pass —
// but enforcement (derouting un-attested providers) only begins once a deadline
// is reached (SetCodeAttestationDeadline). So configuring the attestor alone is
// SAFE: the fleet stays in grace/observe mode and keeps routing. Passing nil
// leaves the feature disabled. Call once during server setup, before providers
// connect.
func (s *Server) SetCodeAttestor(a apns.CodeIdentityAttestor) { s.trust.SetCodeAttestor(a) }

// SetCodeAttestationDeadline sets the instant at which code-identity attestation
// becomes mandatory for routing. Before it (or when zero) the coordinator runs in
// grace mode: it challenges providers but still routes un-attested ones, giving
// the fleet time to update to 0.6.0 and attest. Wire it from APNS_ENFORCE_AFTER.
func (s *Server) SetCodeAttestationDeadline(t time.Time) { s.trust.SetCodeAttestationDeadline(t) }

// SetMDMWebhookSecret configures an optional shared secret that MicroMDM must
// present (as ?token= or the X-Webhook-Token header) when calling the webhook.
// When empty, the webhook relies solely on the solicited-command (CommandUUID)
// gate in the MDM client; when set, callers lacking the secret are rejected
// before the body is read. MicroMDM is co-located with the coordinator, so this
// secret never traverses the public network.
func (s *Server) SetMDMWebhookSecret(secret string) { s.trust.SetMDMWebhookSecret(secret) }

// SetKnownBinaryHashes configures the set of accepted provider binary hashes.
// SetBinaryHashEnforcement toggles whether a self-reported binaryHash mismatch
// deroutes a provider. Default false (v0.6.0): binaryHash is demoted to drift
// telemetry; APNs code-identity attestation is the real signal. Enable only for
// rollback or to test the legacy enforcement path.
func (s *Server) SetBinaryHashEnforcement(enabled bool) {
	s.releases.SetBinaryHashEnforcement(enabled)
}

// SetReleaseKey configures the scoped release key for GitHub Actions.
func (s *Server) SetReleaseKey(key string) {
	s.access.SetReleaseKey(key)
}
