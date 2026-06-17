package api

import (
	"context"
	"crypto/x509"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/apns"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/datadog"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/profilesign"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/telemetry"
)

// NewServer creates a configured Server with all routes mounted.
func NewServer(reg *registry.Registry, st store.Store, cfg ServerConfig, logger *slog.Logger) *Server {
	// Wire the store into the registry for provider fleet persistence.
	reg.SetStore(st)

	s := &Server{
		registry:             reg,
		store:                st,
		ledger:               payments.NewLedger(st),
		logger:               logger,
		mux:                  http.NewServeMux(),
		knownRuntimeManifest: &RuntimeManifest{},
		metrics:              NewMetrics(),
		telemetryLimiter:     newTelemetryLimiter(),
		readCache:            newTTLCache(),
		geoResolver:          newProviderGeoResolverFromEnv(logger),
		apiKeyCache:          make(map[string]apiKeyCacheEntry),
		pendingACME:          make(map[string]*ACMEVerificationResult),
		codeAttestThrottle:   newCodeAttestThrottle(),
		settlements:          newSettlementHolder(),
		zombieCanceller:      newZombieStreamCanceller(),
		serviceReservations:  newServiceReservationManager(st, cfg.ServiceReservations),
		routeTelemetry:       newTelemetrySink(logger, defaultTelemetrySinkCapacity, defaultTelemetrySinkWorkers),
	}
	s.registerDefaultGauges()
	s.routes()

	// Load stored provider records into a lookup table for matching
	// reconnecting providers to their persisted state.
	s.storedProviders = reg.LoadStoredProviders()
	// Apply server configuration from ServerConfig.
	// TODO(auth): storing admin emails in the server struct is an antipattern.
	// Move admin verification to an external auth service (Privy or IDP) so that
	// the server doesn't need to hold email state.
	s.adminKey = cfg.AdminKey
	if len(cfg.AdminEmails) > 0 {
		s.adminEmails = make(map[string]bool)
		for _, e := range cfg.AdminEmails {
			s.adminEmails[strings.ToLower(strings.TrimSpace(e))] = true
		}
	}
	s.consoleURL = cfg.ConsoleURL
	s.corsOrigin = cfg.CORSOrigin
	s.baseURL = strings.TrimRight(cfg.BaseURL, "/")
	s.minProviderVersion = strings.TrimSpace(cfg.MinProviderVersion)
	s.r2CDNURL = strings.TrimRight(cfg.R2CDNURL, "/")
	s.r2SitePackagesCDNURL = strings.TrimRight(cfg.R2SitePackagesCDNURL, "/")
	s.releaseKey = cfg.ReleaseKey

	return s
}

// SetAdminKey configures the admin API key for admin-only endpoints.
func (s *Server) SetAdminKey(key string) {
	s.adminKey = key
}

// SetMinProviderVersion sets the minimum provider version for routing.
func (s *Server) SetMinProviderVersion(v string) {
	s.minProviderVersion = strings.TrimSpace(v)
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
	s.r2CDNURL = strings.TrimRight(url, "/")
}

// SetEmitter wires the coordinator-side telemetry emitter. Call once at boot.
func (s *Server) SetEmitter(e *telemetry.Emitter) {
	s.emitter = e
}

// SetDatadog wires the Datadog client for DogStatsD metrics and Logs API forwarding.
func (s *Server) SetDatadog(dd *datadog.Client) {
	s.dd = dd
}

// Datadog returns the Datadog client (or nil). Exposed so main.go and the
// telemetry emitter can share the same client.
func (s *Server) Datadog() *datadog.Client {
	return s.dd
}

// Metrics returns the in-process metrics registry so cmd/coordinator can
// expose it to the telemetry emitter and other integrations.
func (s *Server) Metrics() *Metrics {
	return s.metrics
}

// emit is an internal convenience that funnels events through the emitter if
// one has been wired up. No-op otherwise — telemetry must never affect control
// flow.
func (s *Server) emit(ctx context.Context, severity protocol.TelemetrySeverity, kind protocol.TelemetryKind, message string, fields map[string]any) {
	if s.emitter == nil {
		return
	}
	s.emitter.Emit(telemetry.Event{
		Severity: severity,
		Kind:     kind,
		Message:  message,
		Fields:   fields,
	})
}

// emitRequest is like emit but preserves a request_id for correlation.
func (s *Server) emitRequest(ctx context.Context, severity protocol.TelemetrySeverity, requestID, message string, fields map[string]any) {
	if s.emitter == nil {
		return
	}
	s.emitter.Emit(telemetry.Event{
		Severity:  severity,
		Kind:      protocol.KindInferenceError,
		Message:   message,
		Fields:    fields,
		RequestID: requestID,
	})
}

// ddIncr increments a DogStatsD counter. No-op if DD is not configured.
func (s *Server) ddIncr(name string, tags []string) {
	if s.dd != nil {
		s.dd.Incr(name, tags)
	}
}

// ddCount increments a DogStatsD counter by the given value. No-op if DD is not configured.
func (s *Server) ddCount(name string, value int64, tags []string) {
	if s.dd != nil {
		s.dd.Count(name, value, tags)
	}
}

// ddHistogram records a DogStatsD histogram value. No-op if DD is not configured.
func (s *Server) ddHistogram(name string, value float64, tags []string) {
	if s.dd != nil {
		s.dd.Histogram(name, value, tags)
	}
}

// ddGauge sets a DogStatsD gauge value. No-op if DD is not configured.
func (s *Server) ddGauge(name string, value float64, tags []string) {
	if s.dd != nil {
		s.dd.Gauge(name, value, tags)
	}
}

func (s *Server) emitPanic(ctx context.Context, message, stack string, fields map[string]any) {
	if s.emitter == nil {
		return
	}
	s.emitter.Emit(telemetry.Event{
		Severity: protocol.SeverityFatal,
		Kind:     protocol.KindPanic,
		Message:  message,
		Fields:   fields,
		Stack:    stack,
	})
}

// SetStepCACerts configures the step-ca CA certificates for ACME client cert verification.
func (s *Server) SetStepCACerts(root, intermediate *x509.Certificate) {
	s.stepCARootCert = root
	s.stepCAIntermediateCert = intermediate
}

// SetProfileSigner configures the CMS signing identity used to sign the
// enrollment .mobileconfig served by /v1/enroll. When unset (nil), profiles are
// served unsigned (the historical behaviour).
func (s *Server) SetProfileSigner(signer *profilesign.Signer) {
	s.profileSigner = signer
}

// SetBilling configures the billing service for multi-chain payments and referrals.
func (s *Server) SetBilling(svc *billing.Service) {
	s.billing = svc
}

func (s *Server) Billing() *billing.Service {
	return s.billing
}

func (s *Server) SetChallengeInterval(d time.Duration) {
	s.challengeInterval = d
}

func (s *Server) SetSkipChallenge(skip bool) {
	s.skipChallenge = skip
}

// SetPrivyAuth configures Privy JWT authentication for consumer endpoints.
func (s *Server) SetPrivyAuth(pa *auth.PrivyAuth) {
	s.privyAuth = pa
}

// SetAdminEmails configures which Privy accounts have admin access.
func (s *Server) SetAdminEmails(emails []string) {
	s.adminEmails = make(map[string]bool, len(emails))
	for _, e := range emails {
		s.adminEmails[strings.ToLower(strings.TrimSpace(e))] = true
	}
}

// SetMDMClient configures the MicroMDM client for provider verification.
// When set, providers are verified against MDM on registration.
func (s *Server) SetMDMClient(client *mdm.Client) {
	s.mdmClient = client
}

// SetCodeAttestor wires the APNs code-identity attestor (v0.6.0). When set, the
// coordinator issues code-identity challenges and measures which providers pass —
// but enforcement (derouting un-attested providers) only begins once a deadline
// is reached (SetCodeAttestationDeadline). So configuring the attestor alone is
// SAFE: the fleet stays in grace/observe mode and keeps routing. Passing nil
// leaves the feature disabled. Call once during server setup, before providers
// connect.
func (s *Server) SetCodeAttestor(a apns.CodeIdentityAttestor) {
	s.codeAttestor = a
	s.registry.SetCodeAttestationConfigured(a != nil)
}

// SetCodeAttestationDeadline sets the instant at which code-identity attestation
// becomes mandatory for routing. Before it (or when zero) the coordinator runs in
// grace mode: it challenges providers but still routes un-attested ones, giving
// the fleet time to update to 0.6.0 and attest. Wire it from APNS_ENFORCE_AFTER.
func (s *Server) SetCodeAttestationDeadline(t time.Time) {
	s.registry.SetCodeAttestationDeadline(t)
}

// SetMDMWebhookSecret configures an optional shared secret that MicroMDM must
// present (as ?token= or the X-Webhook-Token header) when calling the webhook.
// When empty, the webhook relies solely on the solicited-command (CommandUUID)
// gate in the MDM client; when set, callers lacking the secret are rejected
// before the body is read. MicroMDM is co-located with the coordinator, so this
// secret never traverses the public network.
func (s *Server) SetMDMWebhookSecret(secret string) {
	s.mdmWebhookSecret = secret
}
