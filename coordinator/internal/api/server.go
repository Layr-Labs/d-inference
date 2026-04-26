// Package api provides the HTTP and WebSocket server for the Darkbloom coordinator.
//
// This package is the network-facing layer of the coordinator. It handles:
//   - Consumer HTTP endpoints (OpenAI-compatible chat completions, model listing)
//   - Provider WebSocket connections (registration, heartbeats, inference relay)
//   - Payment endpoints (deposit, balance, usage)
//   - Authentication via API keys (Bearer token)
//   - CORS middleware for development
//   - Request logging
//
// The coordinator runs in a GCP Confidential VM (AMD SEV-SNP). Consumer traffic
// arrives over HTTPS/TLS. The coordinator reads requests for routing but never
// logs prompt content.
package api

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"crypto/x509"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"runtime/debug"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/coordinator/internal/auth"
	"github.com/eigeninference/coordinator/internal/billing"
	"github.com/eigeninference/coordinator/internal/datadog"
	"github.com/eigeninference/coordinator/internal/e2e"
	"github.com/eigeninference/coordinator/internal/mdm"
	"github.com/eigeninference/coordinator/internal/payments"
	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/ratelimit"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
	"github.com/eigeninference/coordinator/internal/telemetry"
)

// contextKey is an unexported type for context keys in this package.
// Using a distinct type prevents collisions with context keys from other packages.
type contextKey int

const (
	ctxKeyConsumer contextKey = iota
	ctxKeyRequestID
)

// requestIDFromContext returns the per-request correlation ID set by
// the logging middleware. Empty if the request didn't pass through the
// middleware (e.g. raw test handlers).
func requestIDFromContext(ctx context.Context) string {
	if v, ok := ctx.Value(ctxKeyRequestID).(string); ok {
		return v
	}
	return ""
}

// cryptoRand is a small wrapper to read random bytes. Defined as a var
// so tests can stub it if needed; production uses crypto/rand.Read.
var cryptoRand = rand.Read

// consumerKeyFromContext retrieves the authenticated consumer's API key
// from the request context. The key is stored by requireAuth middleware
// and used as the consumer's identity for billing and usage tracking.
func consumerKeyFromContext(ctx context.Context) string {
	if v, ok := ctx.Value(ctxKeyConsumer).(string); ok {
		return v
	}
	return ""
}

// LatestProviderVersion is the fallback version returned only when no
// release has been registered in the store (e.g. in-memory dev setups).
// Production reads the latest version from the releases table.
var LatestProviderVersion = "0.3.10"

// latestReleasedVersion returns the highest active release version from
// the store, falling back to the hardcoded LatestProviderVersion when
// no release record exists.
func (s *Server) latestReleasedVersion() string {
	if release := s.store.GetLatestRelease("macos-arm64"); release != nil {
		return release.Version
	}
	return LatestProviderVersion
}

// Server is the main HTTP/WS server for the coordinator. It ties together
// the provider registry, key store, payment ledger, billing service, and HTTP routing.
type Server struct {
	registry               *registry.Registry
	store                  store.Store
	ledger                 *payments.Ledger
	billing                *billing.Service
	logger                 *slog.Logger
	mux                    *http.ServeMux
	challengeInterval      time.Duration     // 0 means use DefaultChallengeInterval
	privyAuth              *auth.PrivyAuth   // Privy JWT authentication (nil if not configured)
	adminEmails            map[string]bool   // emails that have admin access
	adminKey               string            // EIGENINFERENCE_ADMIN_KEY for admin endpoints
	mdmClient              *mdm.Client       // MicroMDM client for provider security verification
	stepCARootCert         *x509.Certificate // step-ca root CA for ACME cert verification
	stepCAIntermediateCert *x509.Certificate // step-ca intermediate CA

	// knownBinaryHashes is the set of accepted provider binary SHA-256 hashes.
	// When non-empty, providers whose binary hash doesn't match are rejected.
	// Auto-populated from active releases via SyncBinaryHashes().
	knownBinaryHashes map[string]bool

	// knownRuntimeManifest holds accepted runtime component hashes.
	// When set, providers whose runtime hashes don't match are marked as
	// unverified and excluded from routing (but not disconnected).
	knownRuntimeManifest *RuntimeManifest

	// minProviderVersion is the minimum provider version accepted for routing.
	// Providers below this version are excluded and told to update.
	// Set from EIGENINFERENCE_MIN_PROVIDER_VERSION env var or derived from latest release.
	minProviderVersion string

	// releaseKey is a scoped credential for the GitHub Action to register releases.
	// It can only POST /v1/releases — no admin access.
	releaseKey string

	// consoleURL is the frontend URL (e.g. "https://console.darkbloom.dev").
	// Used for device auth verification_uri so the browser opens the console, not the coordinator.
	consoleURL string

	// baseURL is the public URL clients reach this coordinator at
	// (e.g. "https://api.darkbloom.dev" for prod, "https://api.dev.darkbloom.xyz" for dev).
	// Substituted into the embedded install.sh at serve time so the same binary
	// can serve both environments. Falls back to "https://" + request.Host when empty.
	baseURL string

	// r2CDNURL is the public R2 bucket URL that providers pull release artifacts
	// and model weights from. Prod bucket is distinct from dev bucket, so the
	// coordinator substitutes it into install.sh at serve time.
	r2CDNURL string

	// r2SitePackagesCDNURL is the R2 URL for the Python site-packages tarball.
	// Prod historically uses a second bucket; dev can reuse r2CDNURL.
	r2SitePackagesCDNURL string

	// corsOrigin is the allowed CORS origin (e.g. "https://console.darkbloom.dev").
	// Set from CORS_ORIGIN env var. Empty defaults to the production console domain.
	corsOrigin string

	// imageUploads stores generated images keyed by request_id.
	// Providers upload images via HTTP POST, then send a small WebSocket
	// completion message. The consumer handler retrieves images from here.
	imageUploads   map[string][][]byte // request_id → list of PNG images
	imageUploadsMu sync.Mutex

	// storedProviders is a lookup table of persisted provider records, indexed
	// by serial number and SE public key. When a provider reconnects after a
	// coordinator restart, this table is checked to restore trust/reputation.
	// Populated once at startup from the store.
	storedProviders map[string]*store.ProviderRecord

	// coordinatorKey is the long-lived X25519 keypair used to receive sealed
	// requests from senders. Set via SetCoordinatorKey. nil disables the
	// /v1/encryption-key endpoint and the sealed-request middleware.
	coordinatorKey *e2e.CoordinatorKey

	// metrics is the in-process metrics registry exposed via /v1/admin/metrics
	// and used by internal counters/histograms. Never nil.
	metrics *Metrics

	// telemetryLimiter throttles telemetry ingestion per submitter.
	telemetryLimiter *telemetryLimiter

	// readCache memoizes pre-serialized JSON for read-heavy aggregation
	// endpoints (stats, leaderboard, model catalog, etc.). TTLs are
	// per-key. Never nil.
	readCache *ttlCache

	// emitter writes coordinator-side telemetry events (panics, handler
	// failures, attestation failures, etc.). Set via SetEmitter; nil before
	// main.go wires it up.
	emitter *telemetry.Emitter

	// dd is the Datadog integration client for DogStatsD metrics and
	// Logs API event forwarding. Nil when DD is not configured.
	dd *datadog.Client

	// rateLimiter applies per-account token-bucket rate limits to consumer
	// inference endpoints. Nil means unlimited (compatibility with old call
	// sites and tests). Set via SetRateLimiter.
	rateLimiter *ratelimit.Limiter

	// financialRateLimiter is a separate, stricter limiter for endpoints
	// that touch on-chain state or mutate balances (deposit, withdraw, key
	// creation, referral apply, invite redemption). These are higher-value
	// targets for spam/abuse than inference, so we throttle them harder.
	// Nil means unlimited.
	financialRateLimiter *ratelimit.Limiter
}

// SetRateLimiter configures the per-account rate limiter applied to
// consumer inference endpoints. Pass nil to disable.
func (s *Server) SetRateLimiter(rl *ratelimit.Limiter) {
	s.rateLimiter = rl
}

// SetFinancialRateLimiter configures a stricter per-account limiter for
// balance-mutating endpoints. Pass nil to disable.
func (s *Server) SetFinancialRateLimiter(rl *ratelimit.Limiter) {
	s.financialRateLimiter = rl
}

// NewServer creates a configured Server with all routes mounted.
func NewServer(reg *registry.Registry, st store.Store, logger *slog.Logger) *Server {
	// Wire the store into the registry for provider fleet persistence.
	reg.SetStore(st)

	s := &Server{
		registry:             reg,
		store:                st,
		ledger:               payments.NewLedger(st),
		logger:               logger,
		mux:                  http.NewServeMux(),
		imageUploads:         make(map[string][][]byte),
		knownRuntimeManifest: &RuntimeManifest{},
		metrics:              NewMetrics(),
		telemetryLimiter:     newTelemetryLimiter(),
		readCache:            newTTLCache(),
	}
	s.registerDefaultGauges()
	s.routes()

	// Load stored provider records into a lookup table for matching
	// reconnecting providers to their persisted state.
	s.storedProviders = reg.LoadStoredProviders()

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

// SetR2SitePackagesCDNURL sets the R2 URL for the Python site-packages
// tarball. Defaults to r2CDNURL when unset.
func (s *Server) SetR2SitePackagesCDNURL(url string) {
	s.r2SitePackagesCDNURL = strings.TrimRight(url, "/")
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
	s.emitter.Emit(ctx, telemetry.Event{
		Severity: severity,
		Kind:     kind,
		Message:  message,
		Fields:   fields,
	})
}

// emitRequest is like emit but preserves a request_id for correlation.
func (s *Server) emitRequest(ctx context.Context, severity protocol.TelemetrySeverity, kind protocol.TelemetryKind, requestID, message string, fields map[string]any) {
	if s.emitter == nil {
		return
	}
	s.emitter.Emit(ctx, telemetry.Event{
		Severity:  severity,
		Kind:      kind,
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

// emitPanic is the panic-specific emit helper. Captures stack separately.
func (s *Server) emitPanic(ctx context.Context, message, stack string, fields map[string]any) {
	if s.emitter == nil {
		return
	}
	s.emitter.Emit(ctx, telemetry.Event{
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

// SetBilling configures the billing service for multi-chain payments and referrals.
func (s *Server) SetBilling(svc *billing.Service) {
	s.billing = svc
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

// SyncModelCatalog reads active models from the store and updates the
// registry's model catalog. Call this at startup and after admin catalog changes.
func (s *Server) SyncModelCatalog() {
	models := s.store.ListSupportedModels()
	entries := make([]registry.CatalogEntry, 0, len(models))
	for _, m := range models {
		if m.Active {
			entries = append(entries, registry.CatalogEntry{
				ID:         m.ID,
				WeightHash: m.WeightHash,
				SizeGB:     m.SizeGB,
			})
		}
	}
	s.registry.SetModelCatalog(entries)
	s.logger.Info("model catalog synced to registry", "active_models", len(entries))
}

// SetKnownBinaryHashes configures the set of accepted provider binary hashes.
// Providers whose binary SHA-256 doesn't match any known hash are rejected.
func (s *Server) SetKnownBinaryHashes(hashes []string) {
	s.knownBinaryHashes = make(map[string]bool, len(hashes))
	for _, h := range hashes {
		if h != "" {
			s.knownBinaryHashes[h] = true
		}
	}
}

// AddKnownBinaryHashes adds hashes to the existing known set (for env var fallback).
func (s *Server) AddKnownBinaryHashes(hashes []string) {
	if s.knownBinaryHashes == nil {
		s.knownBinaryHashes = make(map[string]bool)
	}
	for _, h := range hashes {
		if h != "" {
			s.knownBinaryHashes[h] = true
		}
	}
}

// SetConsoleURL sets the frontend URL for device auth verification links.
func (s *Server) SetConsoleURL(url string) {
	s.consoleURL = url
}

// SetCORSOrigin configures the allowed CORS origin.
func (s *Server) SetCORSOrigin(origin string) {
	s.corsOrigin = origin
}

// SetReleaseKey configures the scoped release key for GitHub Actions.
func (s *Server) SetReleaseKey(key string) {
	s.releaseKey = key
}

// SetCoordinatorKey installs the X25519 keypair the coordinator publishes
// for sender-to-coordinator request encryption. Pass nil to disable.
func (s *Server) SetCoordinatorKey(k *e2e.CoordinatorKey) {
	s.coordinatorKey = k
}

// CoordinatorKey returns the configured coordinator encryption key (or nil).
// Exposed for tests; production code should not need this.
func (s *Server) CoordinatorKey() *e2e.CoordinatorKey {
	return s.coordinatorKey
}

// SyncBinaryHashes rebuilds knownBinaryHashes from all active releases.
// Called at startup and after release changes.
func (s *Server) SyncBinaryHashes() {
	releases := s.store.ListReleases()
	hashes := make(map[string]bool)
	for _, r := range releases {
		if r.Active && r.BinaryHash != "" {
			hashes[r.BinaryHash] = true
		}
	}
	s.knownBinaryHashes = hashes
	s.logger.Info("binary hashes synced from releases", "known_hashes", len(hashes))
}

// SyncRuntimeManifest builds the runtime manifest from active releases.
// Called after a release is registered to auto-update the expected hashes.
func (s *Server) SyncRuntimeManifest() {
	releases := s.store.ListReleases()

	// Minimum provider version is set manually via EIGENINFERENCE_MIN_PROVIDER_VERSION
	// env var. It is NOT auto-derived from the latest release — pushing a new release
	// should not instantly knock all existing providers offline.

	manifest := &RuntimeManifest{
		PythonHashes:   make(map[string]bool),
		RuntimeHashes:  make(map[string]bool),
		TemplateHashes: make(map[string]string),
	}

	// Sort releases ascending by version so newer releases' template hashes
	// overwrite older ones (templates are keyed by name; binary/runtime hashes
	// accumulate as a set).
	sortedReleases := append([]store.Release(nil), releases...)
	sort.SliceStable(sortedReleases, func(i, j int) bool {
		return semverGreater(sortedReleases[j].Version, sortedReleases[i].Version)
	})

	hasAny := false
	for _, r := range sortedReleases {
		if !r.Active {
			continue
		}
		if r.PythonHash != "" {
			manifest.PythonHashes[r.PythonHash] = true
			hasAny = true
		}
		if r.RuntimeHash != "" {
			manifest.RuntimeHashes[r.RuntimeHash] = true
			hasAny = true
		}
		if r.TemplateHashes != "" {
			// Parse "name=hash,name=hash" format
			for _, pair := range strings.Split(r.TemplateHashes, ",") {
				parts := strings.SplitN(strings.TrimSpace(pair), "=", 2)
				if len(parts) == 2 {
					manifest.TemplateHashes[parts[0]] = parts[1]
					hasAny = true
				}
			}
		}
	}

	if hasAny {
		s.knownRuntimeManifest = manifest
		s.logger.Info("runtime manifest synced from releases",
			"python_hashes", len(manifest.PythonHashes),
			"runtime_hashes", len(manifest.RuntimeHashes),
			"template_hashes", len(manifest.TemplateHashes),
		)
	} else {
		s.knownRuntimeManifest = nil
	}

	s.revalidateConnectedProvidersAgainstRuntimePolicy()
}

func (s *Server) revalidateConnectedProvidersAgainstRuntimePolicy() {
	for _, providerID := range s.registry.ProviderIDs() {
		provider := s.registry.GetProvider(providerID)
		if provider == nil {
			continue
		}

		provider.Mu().Lock()
		pythonHash := provider.PythonHash
		runtimeHash := provider.RuntimeHash
		templateHashes := registry.CloneStringMap(provider.TemplateHashes)
		version := provider.Version
		switch {
		case s.knownRuntimeManifest == nil:
			provider.RuntimeVerified = false
			provider.RuntimeManifestChecked = false
		case s.minProviderVersion != "" &&
			version != "" &&
			semverLess(version, s.minProviderVersion):
			provider.RuntimeVerified = false
			provider.RuntimeManifestChecked = false
		default:
			runtimeOK, _ := s.verifyRuntimeHashes(
				pythonHash,
				runtimeHash,
				templateHashes,
			)
			if !runtimeOK {
				provider.RuntimeVerified = false
				provider.RuntimeManifestChecked = false
			}
		}
		provider.Mu().Unlock()
	}
}

// RuntimeManifest holds the set of accepted hashes for provider runtime components.
// When configured, the coordinator verifies provider-reported hashes against
// this manifest at registration and during periodic attestation challenges.
type RuntimeManifest struct {
	PythonHashes   map[string]bool   `json:"python_hashes"`   // set of accepted Python runtime hashes
	RuntimeHashes  map[string]bool   `json:"runtime_hashes"`  // set of accepted inference runtime hashes
	TemplateHashes map[string]string `json:"template_hashes"` // template_name -> expected hash
}

// SetRuntimeManifest configures the known-good runtime manifest for provider
// verification. Pass nil to disable runtime verification (all providers pass).
// semverGreater returns true if version a is greater than version b.
// Compares numeric components (e.g. "0.2.31" > "0.2.9" = true).
func semverGreater(a, b string) bool {
	if a == "" {
		return false
	}
	if b == "" {
		return true
	}
	aParts := strings.Split(a, ".")
	bParts := strings.Split(b, ".")
	for i := 0; i < len(aParts) || i < len(bParts); i++ {
		var ai, bi int
		if i < len(aParts) {
			fmt.Sscanf(aParts[i], "%d", &ai)
		}
		if i < len(bParts) {
			fmt.Sscanf(bParts[i], "%d", &bi)
		}
		if ai > bi {
			return true
		}
		if ai < bi {
			return false
		}
	}
	return false // equal
}

// semverLess returns true if version a is less than version b.
func semverLess(a, b string) bool {
	return semverGreater(b, a)
}

func (s *Server) SetRuntimeManifest(m *RuntimeManifest) {
	s.knownRuntimeManifest = m
}

// verifyRuntimeHashes checks provider-reported runtime hashes against the
// known-good manifest. When a component has expected hashes in the manifest,
// the provider MUST report that component and it MUST match one of the known
// good values. Omitting a required hash is treated as a mismatch.
func (s *Server) verifyRuntimeHashes(pythonHash, runtimeHash string, templateHashes map[string]string) (bool, []protocol.RuntimeMismatch) {
	if s.knownRuntimeManifest == nil {
		return true, nil
	}

	manifest := s.knownRuntimeManifest
	var mismatches []protocol.RuntimeMismatch

	requireOneOf := func(component, got string, accepted map[string]bool) {
		if len(accepted) == 0 {
			return
		}
		if got == "" {
			mismatches = append(mismatches, protocol.RuntimeMismatch{
				Component: component,
				Expected:  "reported hash matching one of known-good values",
				Got:       "(missing)",
			})
			return
		}
		if !accepted[got] {
			mismatches = append(mismatches, protocol.RuntimeMismatch{
				Component: component,
				Expected:  "one of known-good hashes",
				Got:       got,
			})
		}
	}

	requireOneOf("python", pythonHash, manifest.PythonHashes)
	requireOneOf("runtime", runtimeHash, manifest.RuntimeHashes)

	if len(manifest.TemplateHashes) > 0 {
		for name, expected := range manifest.TemplateHashes {
			got, ok := templateHashes[name]
			if !ok || got == "" {
				mismatches = append(mismatches, protocol.RuntimeMismatch{
					Component: "template:" + name,
					Expected:  expected,
					Got:       "(missing)",
				})
				continue
			}
			if got != expected {
				mismatches = append(mismatches, protocol.RuntimeMismatch{
					Component: "template:" + name,
					Expected:  expected,
					Got:       got,
				})
			}
		}
		for name, got := range templateHashes {
			if _, ok := manifest.TemplateHashes[name]; !ok {
				mismatches = append(mismatches, protocol.RuntimeMismatch{
					Component: "template:" + name,
					Expected:  "template listed in runtime manifest",
					Got:       got,
				})
			}
		}
	}

	return len(mismatches) == 0, mismatches
}

// handleRuntimeManifest returns the current runtime manifest as JSON.
// No auth required — hashes are not secrets.
func (s *Server) handleRuntimeManifest(w http.ResponseWriter, r *http.Request) {
	const cacheKey = "runtime_manifest:v1"
	if cached, ok := s.readCache.Get(cacheKey); ok {
		writeCachedJSON(w, http.StatusOK, cached)
		return
	}
	var resp map[string]any
	if s.knownRuntimeManifest == nil {
		resp = map[string]any{"configured": false}
	} else {
		resp = map[string]any{
			"configured":      true,
			"python_hashes":   s.knownRuntimeManifest.PythonHashes,
			"runtime_hashes":  s.knownRuntimeManifest.RuntimeHashes,
			"template_hashes": s.knownRuntimeManifest.TemplateHashes,
		}
	}
	body, err := json.Marshal(resp)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to encode manifest"))
		return
	}
	s.readCache.Set(cacheKey, body, time.Minute)
	writeCachedJSON(w, http.StatusOK, body)
}

// HandleMDMWebhook processes a MicroMDM webhook callback.
// Mount this on the webhook URL configured in MicroMDM.
func (s *Server) HandleMDMWebhook(w http.ResponseWriter, r *http.Request) {
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

//go:embed install.sh
var installScript []byte

// installScriptPlaceholder is substituted with the coordinator's public URL at
// serve time. Keep in sync with coordinator/internal/api/install.sh.
const installScriptPlaceholder = "__DARKBLOOM_COORD_URL__"

// installScriptR2Placeholder is substituted with the public R2 CDN URL for
// release artifacts + model weights. Keep in sync with install.sh.
const installScriptR2Placeholder = "__DARKBLOOM_R2_CDN_URL__"

// installScriptR2SitePackagesPlaceholder is substituted with the R2 URL for
// the Python site-packages tarball (historically a separate prod bucket).
const installScriptR2SitePackagesPlaceholder = "__DARKBLOOM_R2_SITE_PACKAGES_CDN_URL__"

// resolveBaseURL returns the configured baseURL, or derives one from the
// request's Host header when baseURL is unset. TLS-terminating proxies pass
// through the original scheme via X-Forwarded-Proto; default to https.
func (s *Server) resolveBaseURL(r *http.Request) string {
	if s.baseURL != "" {
		return s.baseURL
	}
	scheme := "https"
	if proto := r.Header.Get("X-Forwarded-Proto"); proto != "" {
		scheme = proto
	} else if r.TLS == nil {
		scheme = "http"
	}
	return scheme + "://" + r.Host
}

// routes mounts all HTTP and WebSocket handlers.
func (s *Server) routes() {
	// Install script — served from embedded binary with coordinator URL +
	// R2 CDN URLs substituted per environment.
	s.mux.HandleFunc("GET /install.sh", func(w http.ResponseWriter, r *http.Request) {
		rendered := strings.ReplaceAll(string(installScript), installScriptPlaceholder, s.resolveBaseURL(r))
		rendered = strings.ReplaceAll(rendered, installScriptR2Placeholder, s.r2CDNURL)
		sitePackagesURL := s.r2SitePackagesCDNURL
		if sitePackagesURL == "" {
			sitePackagesURL = s.r2CDNURL
		}
		rendered = strings.ReplaceAll(rendered, installScriptR2SitePackagesPlaceholder, sitePackagesURL)
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
		io.WriteString(w, rendered)
	})

	// Health check — no auth required.
	s.mux.HandleFunc("GET /health", s.handleHealth)

	// Provider WebSocket — no API key auth (providers authenticate differently).
	s.mux.HandleFunc("GET /ws/provider", s.handleProviderWS)

	// Key management — requires interactive Privy session (API keys rejected
	// to prevent self-replication from a leaked key).
	s.mux.HandleFunc("POST /v1/auth/keys", s.requirePrivyAuth(s.rateLimitFinancial(s.handleCreateKey)))
	s.mux.HandleFunc("DELETE /v1/auth/keys", s.requirePrivyAuth(s.handleRevokeKey))

	// Consumer endpoints — API key auth required + per-account rate limit.
	// Inference endpoints are wrapped in sealedTransport so senders can opt into
	// sender→coordinator encryption by setting Content-Type:
	// application/eigeninference-sealed+json (see sender_encryption.go).
	// rateLimitConsumer is chained inside requireAuth so the accountID is in
	// context. Read-only endpoints (GET /v1/models) skip rate limiting since
	// they're cheap and clients poll them.
	s.mux.HandleFunc("POST /v1/chat/completions", s.requireAuth(s.rateLimitConsumer(s.sealedTransport(s.handleChatCompletions))))
	s.mux.HandleFunc("POST /v1/responses", s.requireAuth(s.rateLimitConsumer(s.sealedTransport(s.handleChatCompletions)))) // Responses API — same handler, auto-detects input vs messages
	s.mux.HandleFunc("POST /v1/completions", s.requireAuth(s.rateLimitConsumer(s.sealedTransport(s.handleCompletions))))
	s.mux.HandleFunc("POST /v1/messages", s.requireAuth(s.rateLimitConsumer(s.sealedTransport(s.handleAnthropicMessages))))
	s.mux.HandleFunc("GET /v1/models", s.requireAuth(s.handleListModels))

	// Sender encryption — public key publication for sender→coordinator E2E.
	// Optional: senders may use this to encrypt request bodies; plaintext path
	// continues to work unchanged when this header isn't set.
	s.mux.HandleFunc("GET /v1/encryption-key", s.handleEncryptionKey)

	// MDM webhook — MicroMDM sends command responses here.
	s.mux.HandleFunc("POST /v1/mdm/webhook", s.HandleMDMWebhook)

	// Payment endpoints — API key auth required.
	s.mux.HandleFunc("GET /v1/payments/balance", s.requireAuth(s.handleBalance))
	s.mux.HandleFunc("GET /v1/payments/usage", s.requireAuth(s.handleUsage))

	// Provider earnings — no API key auth (providers identify by wallet address).
	s.mux.HandleFunc("GET /v1/provider/earnings", s.handleProviderEarnings)

	// Per-node provider earnings — public by provider_key, or auth'd by account.
	s.mux.HandleFunc("GET /v1/provider/node-earnings", s.handleNodeEarnings)
	s.mux.HandleFunc("GET /v1/provider/account-earnings", s.requireAuth(s.handleAccountEarnings))

	// Account-scoped provider dashboard.
	s.mux.HandleFunc("GET /v1/me/providers", s.requirePrivyAuth(s.handleMyProviders))
	s.mux.HandleFunc("GET /v1/me/summary", s.requirePrivyAuth(s.handleMySummary))

	// ACME enrollment — generates per-device .mobileconfig for device-attest-01.
	// No auth needed — security comes from Apple's attestation during ACME challenge.
	s.mux.HandleFunc("POST /v1/enroll", s.handleEnroll)

	// Attestation verification — public, no auth needed.
	// Users can independently verify Apple's MDA certificate chain.
	s.mux.HandleFunc("GET /v1/providers/attestation", s.handleProviderAttestation)

	// Platform stats — no auth needed. Frontend dashboard uses this.
	s.mux.HandleFunc("GET /v1/stats", s.handleStats)

	// Public leaderboard + network totals — no auth, pseudonymized,
	// 5-min/1-min cache.
	s.mux.HandleFunc("GET /v1/leaderboard", s.handleLeaderboard)
	s.mux.HandleFunc("GET /v1/network/totals", s.handleNetworkTotals)

	// Provider version check — no auth needed. Providers call this to check for updates.
	s.mux.HandleFunc("GET /api/version", s.handleVersion)

	// Releases — versioned provider binary distribution.
	s.mux.HandleFunc("POST /v1/releases", s.handleRegisterRelease)     // scoped release key (GitHub Action)
	s.mux.HandleFunc("GET /v1/releases/latest", s.handleLatestRelease) // public (install.sh)

	// Device authorization flow — providers link to user accounts.
	s.mux.HandleFunc("POST /v1/device/code", s.handleDeviceCode)   // no auth — provider not yet authenticated
	s.mux.HandleFunc("POST /v1/device/token", s.handleDeviceToken) // no auth — polls with device_code secret
	// Device approve issues a long-lived provider→account linking token —
	// same risk class as /v1/auth/keys, so financial-tier limit applies.
	// Uses requirePrivyAuth to reject API keys (interactive session only).
	s.mux.HandleFunc("POST /v1/device/approve", s.requirePrivyAuth(s.rateLimitFinancial(s.handleDeviceApprove)))

	// --- Billing endpoints (Stripe payments + referrals) ---

	// Stripe — financial limiter on session creation (creates a checkout
	// intent, hits external API). Read-only status endpoint not throttled.
	s.mux.HandleFunc("POST /v1/billing/stripe/create-session", s.requireAuth(s.rateLimitFinancial(s.handleStripeCreateSession)))
	s.mux.HandleFunc("POST /v1/billing/stripe/webhook", s.handleStripeWebhook) // no auth — Stripe signs it
	s.mux.HandleFunc("GET /v1/billing/stripe/session", s.requireAuth(s.handleStripeSessionStatus))

	// Wallet balance
	s.mux.HandleFunc("GET /v1/billing/wallet/balance", s.requireAuth(s.handleWalletBalance))

	// Stripe Payouts (Connect Express) — bank/card withdrawals.
	s.mux.HandleFunc("POST /v1/billing/stripe/onboard", s.requireAuth(s.handleStripeOnboard))
	s.mux.HandleFunc("GET /v1/billing/stripe/status", s.requireAuth(s.handleStripeStatus))
	s.mux.HandleFunc("POST /v1/billing/withdraw/stripe", s.requireAuth(s.handleStripeWithdraw))
	s.mux.HandleFunc("GET /v1/billing/stripe/withdrawals", s.requireAuth(s.handleStripeWithdrawals))
	s.mux.HandleFunc("POST /v1/billing/stripe/connect/webhook", s.handleStripeConnectWebhook) // no auth — Stripe signs it

	// Pricing — GET is public, PUT/DELETE require auth
	s.mux.HandleFunc("GET /v1/pricing", s.handleGetPricing)                        // public
	s.mux.HandleFunc("PUT /v1/pricing", s.requireAuth(s.handleSetPricing))         // provider sets own prices
	s.mux.HandleFunc("DELETE /v1/pricing", s.requireAuth(s.handleDeletePricing))   // revert to default
	s.mux.HandleFunc("PUT /v1/admin/pricing", s.requireAuth(s.handleAdminPricing)) // platform sets defaults

	// Admin model catalog
	s.mux.HandleFunc("GET /v1/admin/models", s.requireAuth(s.handleAdminListModels))
	s.mux.HandleFunc("POST /v1/admin/models", s.requireAuth(s.handleAdminSetModel))
	s.mux.HandleFunc("DELETE /v1/admin/models", s.requireAuth(s.handleAdminDeleteModel))
	s.mux.HandleFunc("GET /v1/admin/releases", s.handleAdminListReleases)     // admin key or Privy admin
	s.mux.HandleFunc("DELETE /v1/admin/releases", s.handleAdminDeleteRelease) // admin key or Privy admin

	// Admin CLI auth — Privy email OTP for getting admin tokens without a browser.
	s.mux.HandleFunc("POST /v1/admin/auth/init", s.handleAdminAuthInit)     // no auth (sends OTP)
	s.mux.HandleFunc("POST /v1/admin/auth/verify", s.handleAdminAuthVerify) // no auth (returns token)

	// Public model catalog — providers and install script fetch this
	s.mux.HandleFunc("GET /v1/models/catalog", s.handleModelCatalog)

	// Runtime manifest — providers and users can inspect accepted runtime hashes.
	s.mux.HandleFunc("GET /v1/runtime/manifest", s.handleRuntimeManifest)

	// Payment methods info
	s.mux.HandleFunc("GET /v1/billing/methods", s.handleBillingMethods) // no auth needed

	// Referral system — register/apply mutate referral graph (financial
	// limiter); stats/info are read-only.
	s.mux.HandleFunc("POST /v1/referral/register", s.requireAuth(s.rateLimitFinancial(s.handleReferralRegister)))
	s.mux.HandleFunc("POST /v1/referral/apply", s.requireAuth(s.rateLimitFinancial(s.handleReferralApply)))
	s.mux.HandleFunc("GET /v1/referral/stats", s.requireAuth(s.handleReferralStats))
	s.mux.HandleFunc("GET /v1/referral/info", s.requireAuth(s.handleReferralInfo))

	// Invite codes (admin)
	// Invite code creation accepts amount_usd and produces a credit-bearing
	// code; redemption is already financial-tier so the issuance side must
	// match (otherwise an admin-key holder could spam codes anyway, but
	// keeping symmetry).
	s.mux.HandleFunc("POST /v1/admin/invite-codes", s.requireAuth(s.rateLimitFinancial(s.handleAdminCreateInviteCode)))
	s.mux.HandleFunc("GET /v1/admin/invite-codes", s.requireAuth(s.handleAdminListInviteCodes))
	s.mux.HandleFunc("DELETE /v1/admin/invite-codes", s.requireAuth(s.handleAdminDeactivateInviteCode))

	// Invite code redemption (user) — credits the redeemer's balance, so
	// it's a financial-tier endpoint.
	s.mux.HandleFunc("POST /v1/invite/redeem", s.requireAuth(s.rateLimitFinancial(s.handleRedeemInviteCode)))

	// Admin credit & reward
	s.mux.HandleFunc("POST /v1/admin/credit", s.requireAuth(s.handleAdminCredit))
	s.mux.HandleFunc("POST /v1/admin/reward", s.requireAuth(s.handleAdminReward))

	// Telemetry ingestion — authentication is resolved inside the handler
	// because providers, consumers, and anonymous clients all hit this path.
	// Events are forwarded to Datadog; admin read/summary endpoints have been
	// removed (use Datadog Log Explorer).
	s.mux.HandleFunc("POST /v1/telemetry/events", s.handleTelemetryIngest)

	// Metrics snapshot (admin only)
	s.mux.HandleFunc("GET /v1/admin/metrics", s.handleAdminMetrics)
}

// registerDefaultGauges wires live-computed gauges (fleet size, etc.) into
// the metrics registry at construction time.
func (s *Server) registerDefaultGauges() {
	s.metrics.RegisterGauge("providers_online", func() float64 {
		return float64(s.registry.ProviderCount())
	})
	s.metrics.RegisterGauge("pending_image_uploads", func() float64 {
		s.imageUploadsMu.Lock()
		defer s.imageUploadsMu.Unlock()
		return float64(len(s.imageUploads))
	})
}

// StartDDGaugeLoop periodically pushes gauge values to DogStatsD. Gauges
// are point-in-time values and must be pushed regularly (not on-demand like
// counters). Call as a goroutine; stops when ctx is cancelled.
func (s *Server) StartDDGaugeLoop(ctx context.Context) {
	if s.dd == nil {
		return
	}
	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.ddGauge("providers.online", float64(s.registry.ProviderCount()), nil)
			if q := s.registry.Queue(); q != nil {
				s.ddGauge("request_queue.depth", float64(q.TotalSize()), nil)
			}
		}
	}
}

// handleAdminMetrics returns the metrics snapshot in JSON or Prometheus text.
func (s *Server) handleAdminMetrics(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}
	snap := s.metrics.Snapshot()
	if r.URL.Query().Get("format") == "prom" {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(snap.RenderProm()))
		return
	}
	writeJSON(w, http.StatusOK, snap)
}

// Handler returns the root http.Handler with global middleware applied.
// Middleware order (outside-in):
//
//	cors → recover → logging → mux
//
// Recover must sit outside logging so a panic during logging doesn't leak.
func (s *Server) Handler() http.Handler {
	return s.corsMiddleware(s.recoverMiddleware(s.loggingMiddleware(s.mux)))
}

// recoverMiddleware catches panics in any handler, emits a telemetry event
// with the stack trace, and returns 500 to the client. Without this, a single
// nil deref takes down the whole coordinator — panics from tests have hit us
// in production more than once.
func (s *Server) recoverMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				if recErr, ok := rec.(error); ok && errors.Is(recErr, http.ErrAbortHandler) {
					panic(rec)
				}
				stack := string(debug.Stack())
				s.logger.Error("panic in HTTP handler",
					"error", fmt.Sprintf("%v", rec),
					"path", r.URL.Path,
					"method", r.Method,
					"stack", stack,
				)
				s.emitPanic(r.Context(),
					fmt.Sprintf("panic in handler %s %s: %v", r.Method, r.URL.Path, rec),
					stack,
					map[string]any{
						"handler":  r.URL.Path,
						"endpoint": r.URL.Path,
					},
				)
				// Write a 500 if the response hasn't started yet. If the
				// handler already flushed headers (e.g. streaming SSE), we
				// can't do anything useful — the client will see the stream
				// truncated.
				defer func() { _ = recover() }() // guard against double-write
				writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "internal server error"))
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// requireAuth wraps a handler with authentication. It tries Privy JWT first
// (if configured), then falls back to API key validation. The authenticated
// identity is stored in the request context for downstream use.
func (s *Server) requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := extractBearerToken(r)
		if token == "" {
			writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "missing credentials — use Authorization: Bearer <token>"))
			return
		}

		// Try Privy JWT first (JWTs start with "eyJ").
		if s.privyAuth != nil && strings.HasPrefix(token, "eyJ") {
			privyUserID, err := s.privyAuth.VerifyToken(token)
			if err != nil {
				writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "invalid Privy token"))
				return
			}
			user, err := s.privyAuth.GetOrCreateUser(privyUserID)
			if err != nil {
				s.logger.Error("privy: user resolution failed", "error", err)
				writeJSON(w, http.StatusInternalServerError, errorResponse("auth_error", "failed to resolve user"))
				return
			}
			ctx := context.WithValue(r.Context(), ctxKeyConsumer, user.AccountID)
			ctx = context.WithValue(ctx, auth.CtxKeyUser, user)
			next(w, r.WithContext(ctx))
			return
		}

		// Accept admin key (admin endpoints handle further authorization in-handler).
		if s.adminKey != "" && subtle.ConstantTimeCompare([]byte(token), []byte(s.adminKey)) == 1 {
			ctx := context.WithValue(r.Context(), ctxKeyConsumer, "admin")
			next(w, r.WithContext(ctx))
			return
		}

		// Fall back to API key auth.
		if !s.store.ValidateKey(token) {
			writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "invalid API key"))
			return
		}

		// Resolve key → account. If the key is linked to a Privy account,
		// use that account ID and load the user.
		accountID := token
		ctx := r.Context()
		if ownerID := s.store.GetKeyAccount(token); ownerID != "" {
			accountID = ownerID
			if user, err := s.store.GetUserByAccountID(ownerID); err == nil {
				ctx = context.WithValue(ctx, auth.CtxKeyUser, user)
			}
		}

		ctx = context.WithValue(ctx, ctxKeyConsumer, accountID)
		next(w, r.WithContext(ctx))
	}
}

// requirePrivyAuth wraps a handler requiring a Privy JWT session. Unlike
// requireAuth, API keys are rejected. Use for sensitive account operations
// (key creation, device approval) that must not be triggerable by a leaked
// API key.
func (s *Server) requirePrivyAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := extractBearerToken(r)
		if token == "" {
			writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "missing credentials"))
			return
		}
		if s.privyAuth == nil || !strings.HasPrefix(token, "eyJ") {
			writeJSON(w, http.StatusForbidden, errorResponse("forbidden",
				"this endpoint requires an interactive session — API keys are not accepted"))
			return
		}
		privyUserID, err := s.privyAuth.VerifyToken(token)
		if err != nil {
			writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "invalid Privy token"))
			return
		}
		user, err := s.privyAuth.GetOrCreateUser(privyUserID)
		if err != nil {
			s.logger.Error("privy: user resolution failed", "error", err)
			writeJSON(w, http.StatusInternalServerError, errorResponse("auth_error", "failed to resolve user"))
			return
		}
		ctx := context.WithValue(r.Context(), ctxKeyConsumer, user.AccountID)
		ctx = context.WithValue(ctx, auth.CtxKeyUser, user)
		next(w, r.WithContext(ctx))
	}
}

// rateLimitConsumer wraps a consumer-facing handler with per-account rate
// limiting. It must be chained AFTER requireAuth so the accountID is in
// the context. Admin key requests bypass the limiter (they show up as the
// "admin" pseudo-account from requireAuth — we let those through unmetered
// so admin scripts and ops tooling aren't throttled).
//
// Note: Privy users with admin emails (s.adminEmails) currently do NOT
// bypass — they receive a real accountID from requireAuth. This is
// intentional: human admins shouldn't generate enough traffic to hit
// limits, and treating them as untrusted callers preserves the invariant
// that the limiter sees one identity per real user.
//
// Returns 429 with a Retry-After header on rejection. The Retry-After
// duration is the time until at least one token replenishes, clamped to a
// sane maximum to avoid pathological values.
func (s *Server) rateLimitConsumer(next http.HandlerFunc) http.HandlerFunc {
	return s.rateLimitWith(s.rateLimiterFn, next)
}

// rateLimitFinancial wraps a balance-mutating handler with the stricter
// financial-endpoint limiter. Chain inside requireAuth.
func (s *Server) rateLimitFinancial(next http.HandlerFunc) http.HandlerFunc {
	return s.rateLimitWithTier(s.financialRateLimiterFn, "financial", next)
}

// The two getter methods exist so rateLimitWith can read the *current*
// limiter at request time. Routes are registered in routes() during
// NewServer, but SetRateLimiter / SetFinancialRateLimiter are called
// AFTER NewServer in main.go. Capturing the field directly at registration
// time would close over a nil pointer.
func (s *Server) rateLimiterFn() *ratelimit.Limiter          { return s.rateLimiter }
func (s *Server) financialRateLimiterFn() *ratelimit.Limiter { return s.financialRateLimiter }

func (s *Server) rateLimitWith(getLimiter func() *ratelimit.Limiter, next http.HandlerFunc) http.HandlerFunc {
	return s.rateLimitWithTier(getLimiter, "consumer", next)
}

// rateLimitWithTier is the actual implementation; callers thread a label
// for the metrics counter so we can distinguish consumer vs financial
// rejections in dashboards.
func (s *Server) rateLimitWithTier(getLimiter func() *ratelimit.Limiter, tier string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		rl := getLimiter()
		if rl == nil {
			next(w, r)
			return
		}
		accountID := consumerKeyFromContext(r.Context())
		if accountID == "admin" {
			next(w, r)
			return
		}
		if allowed, retryAfter := rl.Allow(accountID); !allowed {
			seconds := int(retryAfter.Seconds())
			if seconds < 1 {
				seconds = 1
			}
			w.Header().Set("Retry-After", strconv.Itoa(seconds))
			w.Header().Set("X-RateLimit-Reset", strconv.FormatInt(time.Now().Add(retryAfter).Unix(), 10))
			s.ddIncr("ratelimit.rejections", []string{"tier:" + tier})
			writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
				"too many requests — slow down and retry after the Retry-After interval"))
			return
		}
		next(w, r)
	}
}

// corsMiddleware sets CORS headers. The allowed origin is derived from the
// CORS_ORIGIN environment variable; if unset it defaults to the production
// console domain. Wildcard (*) is never used in production.
func (s *Server) corsMiddleware(next http.Handler) http.Handler {
	origin := s.corsOrigin
	if origin == "" {
		origin = "https://console.darkbloom.dev"
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", origin)
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		w.Header().Set("Access-Control-Allow-Credentials", "true")

		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}

		next.ServeHTTP(w, r)
	})
}

// loggingMiddleware logs each request using slog and updates HTTP metrics.
func (s *Server) loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}

		// Generate (or honor) a request_id and stash it in context +
		// response headers so logs and the client can correlate.
		reqID := r.Header.Get("X-Request-ID")
		if reqID == "" {
			reqID = newRequestID()
		}
		w.Header().Set("X-Request-ID", reqID)
		ctx := context.WithValue(r.Context(), ctxKeyRequestID, reqID)
		r = r.WithContext(ctx)

		next.ServeHTTP(sw, r)

		dur := time.Since(start)

		// Resolve the route pattern that matched (Go 1.22+ method+path).
		// Falls back to URL.Path when no pattern matched (404).
		route := r.Pattern
		if route == "" {
			route = "unmatched"
		}

		// User correlation: if requireAuth attached an account, include
		// it in the access log. Empty for unauthenticated paths.
		userID := consumerKeyFromContext(ctx)

		s.logger.Info("request",
			"request_id", reqID,
			"method", r.Method,
			"path", r.URL.Path,
			"route", route,
			"status", sw.status,
			"duration_ms", dur.Milliseconds(),
			"remote", r.RemoteAddr,
			"user_id", userID,
		)

		pathLabel := httpPathLabel(route)
		statusStr := strconvItoa(sw.status)

		if s.metrics != nil {
			s.metrics.IncCounter("http_requests_total",
				MetricLabel{"method", r.Method},
				MetricLabel{"path", pathLabel},
				MetricLabel{"status", statusStr},
			)
			s.metrics.ObserveHistogram("http_request_duration_ms",
				float64(dur.Milliseconds()),
				MetricLabel{"method", r.Method},
				MetricLabel{"path", pathLabel},
			)
		}

		// DogStatsD — emit request counter and latency histogram.
		if s.dd != nil {
			tags := []string{
				"method:" + r.Method,
				"path:" + pathLabel,
				"status_code:" + statusStr,
			}
			s.dd.Incr("http.requests", tags)
			s.dd.Histogram("http.latency_ms", float64(dur.Milliseconds()), tags)
		}
	})
}

// httpPathLabel returns a bounded label for HTTP metrics.
// We use the mux route pattern (e.g. "POST /v1/chat/completions")
// instead of URL.Path so attacker-controlled unmatched paths cannot create
// unbounded metric cardinality.
func httpPathLabel(route string) string {
	if route == "" {
		return "unmatched"
	}
	return route
}

// strconvItoa is a shim to avoid pulling strconv into every middleware file.
func strconvItoa(i int) string { return strconv.Itoa(i) }

// newRequestID returns a short, URL-safe request identifier. We avoid
// uuid here because request_id is hot-path and we don't need the entropy
// of a UUID — 12 base32 chars (~60 bits) is plenty to distinguish
// concurrent requests for trace correlation.
func newRequestID() string {
	const alphabet = "0123456789abcdefghijklmnopqrstuv"
	var b [12]byte
	if _, err := cryptoRand(b[:]); err != nil {
		// Fall back to a time-based id; collision risk is negligible for
		// log-correlation purposes.
		t := time.Now().UnixNano()
		return strconv.FormatInt(t, 36)
	}
	for i := range b {
		b[i] = alphabet[int(b[i])&31]
	}
	return string(b[:])
}

// statusWriter wraps http.ResponseWriter to capture the status code
// for logging. It also implements http.Flusher and http.Hijacker by
// delegating to the underlying writer, which is required for SSE
// streaming and WebSocket upgrade respectively.
type statusWriter struct {
	http.ResponseWriter
	status      int
	wroteHeader bool
}

func (sw *statusWriter) WriteHeader(code int) {
	if !sw.wroteHeader {
		sw.status = code
		sw.wroteHeader = true
	}
	sw.ResponseWriter.WriteHeader(code)
}

func (sw *statusWriter) Flush() {
	if f, ok := sw.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// Hijack implements http.Hijacker by delegating to the underlying writer.
// This is required for WebSocket upgrade to work through middleware.
func (sw *statusWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	if hj, ok := sw.ResponseWriter.(http.Hijacker); ok {
		return hj.Hijack()
	}
	return nil, nil, errors.New("underlying ResponseWriter does not implement http.Hijacker")
}

// Unwrap returns the underlying ResponseWriter, allowing the http package
// and websocket libraries to discover interfaces like http.Hijacker.
func (sw *statusWriter) Unwrap() http.ResponseWriter {
	return sw.ResponseWriter
}

// extractBearerToken extracts the token from "Authorization: Bearer <token>".
func extractBearerToken(r *http.Request) string {
	auth := r.Header.Get("Authorization")
	if auth == "" {
		return ""
	}
	parts := strings.SplitN(auth, " ", 2)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "bearer") {
		return ""
	}
	return strings.TrimSpace(parts[1])
}
