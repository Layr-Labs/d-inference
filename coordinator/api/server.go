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
// The coordinator runs in a GCP Confidential VM (AMD SEV). Consumer traffic
// arrives over HTTPS/TLS. The coordinator reads requests for routing but never
// logs prompt content.
package api

import (
	"context"
	_ "embed"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/access/device"
	"github.com/eigeninference/d-inference/coordinator/api/access/keys"
	"github.com/eigeninference/d-inference/coordinator/api/accounts"
	billinghttp "github.com/eigeninference/d-inference/coordinator/api/billing"
	"github.com/eigeninference/d-inference/coordinator/api/billing/payouts"
	"github.com/eigeninference/d-inference/coordinator/api/catalog"
	"github.com/eigeninference/d-inference/coordinator/api/geo"
	infer "github.com/eigeninference/d-inference/coordinator/api/inference"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/api/operations"
	providerapi "github.com/eigeninference/d-inference/coordinator/api/provider"
	trustapi "github.com/eigeninference/d-inference/coordinator/api/provider/trust"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/api/releases"
	"github.com/eigeninference/d-inference/coordinator/api/reporting"
	attestservice "github.com/eigeninference/d-inference/coordinator/appattest/service"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/payments/baserewards"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// LatestProviderVersion is the fallback version returned only when no
// release has been registered in the store (e.g. in-memory dev setups).
// Production reads the latest version from the releases table.
//
// 0.8.1 reverts v0.8.0's fleet default back to the CONTIGUOUS KV backend:
// the paged pool's physical-capacity policy sized fleet KV roughly 10x
// smaller than contiguous, and the resulting token-budget exhaustion
// dominated paged's throughput and prefix-adoption wins. Paged remains
// fully supported behind an explicit `engine_v2_kv_backend = "paged"` (see
// the provider's EngineV2Factory.prepareProductionBackend for the argument).
// 0.8.15 adds the exact Qwen3.8 dense VLM/NAX target and verified inline MTP
// assistant support; model-aware MTP defaults remain provider-side policy.
// Keep this fallback in sync with ProviderCore.version so dev/in-memory
// coordinators advertise the same floor as the Swift binary they expect.
var LatestProviderVersion = "0.9.17"

// Server is the main HTTP/WS server for the coordinator. It ties together
// the provider registry, key store, payment ledger, billing service, and HTTP routing.
type Server struct {
	registry    *registry.Registry
	store       store.Store
	ledger      *payments.Ledger
	billing     *billing.Service
	baseRewards *baserewards.Engine
	logger      *slog.Logger
	mux         *http.ServeMux
	baseURL     string
	corsOrigin  string
	geoResolver geo.Resolver
	readCache   *readcache.Cache

	access      *access.Owner
	keys        *keys.Handler
	device      *device.Handler
	accounts    *accounts.Owner
	billingHTTP *billinghttp.Owner
	payouts     *payouts.Owner
	catalog     *catalog.Owner
	releases    *releases.Owner
	reporting   *reporting.Owner
	observation *observation.Owner
	inference   *infer.Owner
	providers   *providerapi.Owner
	trust       *trustapi.Owner

	operations.Drain
	operations *operations.Handler
}

// Inference exposes the request owner for application configuration.
func (s *Server) Inference() *infer.Owner { return s.inference }

// Trust exposes the verification owner for application callback wiring.
func (s *Server) Trust() *trustapi.Owner { return s.trust }

// NewServer creates a configured Server with all routes mounted.
func NewServer(reg *registry.Registry, st store.Store, cfg ServerConfig, logger *slog.Logger) *Server {
	// Wire the store into the registry for provider fleet persistence.
	reg.SetStore(st)

	s := &Server{
		registry: reg,
		store:    st,
		ledger:   payments.NewLedger(st),
		logger:   logger,
		mux:      http.NewServeMux(),

		readCache:   readcache.New(),
		geoResolver: geo.NewResolverFromEnv(logger),
		access:      access.New(st, logger, maxControlPlaneBodyBytes, access.Hooks{SetOutcomeStage: observation.SetOutcomeStage, StampAuth: observation.StampAuth}),
	}
	s.observation = observation.New(observation.Dependencies{
		Store: st, Registry: reg, Logger: logger, ProfileFallbackGrace: infer.DefaultTerminalSettleGrace + time.Second,
		Hooks: observation.Hooks{
			RoutePattern:               func(r *http.Request) string { _, pattern := s.mux.Handler(r); return pattern },
			RequireAdminKey:            s.access.RequireAdminKey,
			HasAutopilotDemand:         func(ctx context.Context) bool { return infer.AutopilotDemandFromContext(ctx) != nil },
			BindAutopilotDemandProfile: infer.BindAutopilotDemandProfile,
			MinProviderVersion:         func() string { return s.trust.MinProviderVersion() },
			EmitExactCacheDDGauges:     func() { s.inference.EmitExactCacheDDGauges() },
		},
	})
	s.inference = infer.New(infer.Dependencies{
		Registry: reg, Store: st, Ledger: s.ledger, Access: s.access,
		Observation: s.observation, Geo: s.geoResolver, Logger: logger,
	}, infer.Config{
		ServiceReservations:      cfg.ServiceReservations,
		FirstContentDeadlineBase: cfg.FirstContentDeadlineBase,
		FirstContentSLAAccounts:  cfg.FirstContentSLAAccounts, MediaFetch: cfg.MediaFetch,
	})
	s.access.SetRateObservation(s.observation.Incr, observation.StampRateLimit)
	s.reporting = reporting.New(reporting.Dependencies{
		Store: st, Registry: reg, Cache: s.readCache, Logger: logger,
		Incr: s.observation.Incr, RequireAdminKey: s.access.RequireAdminKey,
	})
	s.catalog = catalog.New(reg, st, s.access, s.readCache, logger, catalog.Hooks{ReconcilePromptArtifacts: s.inference.ReconcilePromptArtifacts, IsDraining: s.IsDraining})
	s.releases = releases.New(reg, st, s.access, s.readCache, logger, releases.Hooks{BelowMinProviderVersion: func(v string) bool { return s.trust.BelowMinProviderVersion(v) }, DDIncr: s.observation.Incr, AppAttest: func() *attestservice.Service { return s.trust.AppAttestFeature() }, AppAttestServing: func() bool { return s.trust.AppAttestServing() }, LatestProviderVersion: func() string { return LatestProviderVersion }})
	s.releases.SetR2CDNURL(cfg.R2CDNURL)
	s.trust = trustapi.New(trustapi.Dependencies{Registry: reg, Store: st, Access: s.access, Releases: s.releases, Observation: s.observation, ReadCache: s.readCache, Logger: logger, Hooks: trustapi.Hooks{
		RestoreProviderState: func(ctx context.Context, p *registry.Provider, serial, seKey string, account ...string) error {
			return s.providers.RestorePersistedProviderState(ctx, p, serial, seKey, account...)
		},
		ResolveBaseURL: s.resolveBaseURL,
	}}, trustapi.Config{AppAttest: cfg.AppAttestShadow, MDMScheduler: cfg.MDMScheduler, MinProviderVersion: cfg.MinProviderVersion, DurableTrustReuse: cfg.DurableTrustReuse, TrustReuseJournalPath: cfg.TrustReuseJournalPath})
	s.providers = providerapi.New(providerapi.Dependencies{Registry: reg, Store: st, Trust: s.trust, Releases: s.releases, Catalog: s.catalog, Geo: s.geoResolver, Observation: s.observation, Logger: logger,
		Inference: providerapi.InferenceEvents{Chunk: s.inference.HandleChunk, Accepted: s.inference.HandleInferenceAccepted, CompleteAt: s.inference.HandleCompleteAt, Error: s.inference.HandleInferenceError}})

	s.accounts = accounts.New(accounts.Dependencies{
		Store: st, Registry: reg, Access: s.access, Logger: logger, ReadCache: s.readCache,
		LatestReleasedVersion: s.releases.LatestReleasedVersion,
		MinProviderVersion:    strings.TrimSpace(cfg.MinProviderVersion),
		SelfRouteModelEntries: s.catalog.SelfRouteModelEntries,
	})
	s.billingHTTP = billinghttp.New(billinghttp.Dependencies{
		Store: st, Ledger: s.ledger, Access: s.access, Logger: logger,
		ReadCache: s.readCache, IncrementMetric: s.observation.Incr,
	})
	s.payouts = payouts.New(nil, logger)
	// Registry write-lock wait, by call site. This is the acceptance metric
	// for taking the recorders off the request path: today the wait is only
	// inferable from goroutine dumps.
	reg.SetLockWaitObserver(func(site string, wait time.Duration) {
		s.observation.Histogram("registry.mu.write_wait_ms", float64(wait.Microseconds())/1000, []string{"site:" + site})
	})
	s.trust.Start()
	reg.SetRuntimeCapabilitiesPromotedHook(s.providers.HandleRuntimeCapabilitiesPromoted)
	// The per-identity gate locks that replaced the request-path registry
	// write lock (registry/gate_state.go) report any acquisition wait above
	// 1 ms here, tagged by recorder site, so the new locks stay observable.
	reg.SetGateWaitObserver(func(site string, wait time.Duration) {
		s.observation.Histogram("registry.gate.wait_ms", float64(wait.Microseconds())/1000, []string{"site:" + site})
	})
	s.observation.RegisterDefaultGauges()
	s.inference.RegisterExactCacheGauges()
	s.keys = keys.New(st, s.access)
	s.device = device.New(st, logger, cfg.ConsoleURL, maxControlPlaneBodyBytes)
	s.operations = operations.New(operations.Dependencies{
		Metrics: s.observation.Metrics,
		Drain:   &s.Drain, Access: s.access, Store: st, Logger: logger,
		MaxBodyBytes: maxControlPlaneBodyBytes, TrustSafety: s.trust.TrustSafetyStatus,
		Reject: s.access.WriteTokenRateLimited, ProviderCount: reg.ProviderCount,
		BuildInfo: func() (string, string, string) { return BuildVersion, BuildCommit, BuildDate },
	})
	s.routes()

	// Apply server configuration from ServerConfig.
	s.access.SetAdminKey(cfg.AdminKey)
	if len(cfg.AdminEmails) > 0 {
		s.access.SetAdminEmails(cfg.AdminEmails)
	}
	s.corsOrigin = cfg.CORSOrigin
	s.baseURL = strings.TrimRight(cfg.BaseURL, "/")
	s.access.SetReleaseKey(cfg.ReleaseKey)

	return s
}

// Close releases background resources owned by the Server.
func (s *Server) Close() {
	s.trust.Quiesce()
	s.inference.CloseResources()
	s.observation.FlushRoutes()
	s.trust.CloseAuthority()
	s.observation.CloseProfilesAndOutcomes()
}

// belowMinProviderVersion reports whether a provider reporting version falls
// below the configured routing floor. With no floor configured nothing is
// below it. With a floor configured, an EMPTY version counts as below it: the
// version is optional on the wire, and every provider build that clears any
// real floor reports one, so a missing version must not bypass the floor.

// providerVersionMetricTag is the Datadog tag value for a provider version,
// naming the empty (unreported) version explicitly.

// maxMDMWebhookBodyBytes caps the MicroMDM webhook body. SecurityInfo /
// DevicePropertiesAttestation responses are a few KB; 1 MiB is generous headroom
// while preventing an unauthenticated caller from exhausting memory via an
// unbounded body.
const maxMDMWebhookBodyBytes = 1 << 20 // 1 MiB

// maxRequestBodyBytes is the global ceiling bodyLimitMiddleware applies to every
// request body so no endpoint can be OOM'd by an unbounded POST. It's a coarse
// outer bound that clears every legitimate body with headroom; the hot paths
// self-cap tighter on top (the plaintext-inference path at 16 MiB, sized to the
// provider WS frame budget — see maxInferenceBodyBytes).
const maxRequestBodyBytes = 64 << 20 // 64 MiB

// maxControlPlaneBodyBytes is the tight cap for small unauthenticated
// control-plane JSON (enroll, device token, admin auth) — far below the global
// ceiling so these exposed endpoints buffer at most a few KiB.
const maxControlPlaneBodyBytes = 64 << 10 // 64 KiB

// HandleMDMWebhook processes a MicroMDM webhook callback.
// Mount this on the webhook URL configured in MicroMDM.
//
// Defense layers (the endpoint is reachable but cannot forge trust):
//  1. Body cap — bounds memory for the unauthenticated path.
//  2. Optional shared secret — when configured, rejects callers without it
//     before reading the body.
//  3. Solicited-command gate (in mdm.Client.HandleWebhook) — only responses
//     whose CommandUUID matches a command the coordinator actually issued are
//     acted on, so a forged SecurityInfo can never drive a trust upgrade.

//go:embed install.sh
var installScript []byte

// installScriptPlaceholder is substituted with the coordinator's public URL at
// serve time. coordinator/api/install.sh is generated byte-for-byte from the
// canonical scripts/install.sh by scripts/sync-install-embed.sh.
//
// The legacy install.sh also substituted __DARKBLOOM_R2_CDN_URL__ and
// __DARKBLOOM_R2_SITE_PACKAGES_CDN_URL__ for the Python runtime download.
// Post-Swift-cutover (v0.5.0+) install.sh no longer touches R2 directly --
// model downloads run inside `darkbloom models download` against the public
// R2 CDN -- so only the coordinator URL needs serve-time templating.
const installScriptPlaceholder = "__DARKBLOOM_COORD_URL__"

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

// readCacheJanitorInterval is how often expired readCache entries are reclaimed.
// Get already skips expired entries, so this only frees memory — but without it
// high-cardinality keys (e.g. the per-account "account-earnings:" entries) are
// written and never re-read, so they linger forever and the cache grows unbounded.
const readCacheJanitorInterval = time.Minute

// StartReadCacheJanitor periodically purges expired entries from the read cache
// so it can't grow unbounded. Call as a goroutine; stops when ctx is cancelled.
func (s *Server) StartReadCacheJanitor(ctx context.Context) {
	saferun.Go(s.logger, "model_token_promotion_maintenance", func() { s.inference.RunModelTokenMaintenance(ctx) })
	s.readCache.RunJanitor(ctx, readCacheJanitorInterval)
}

// StartCacheRefreshers starts the reporting owner's independent refresh loops.
func (s *Server) StartCacheRefreshers(ctx context.Context) {
	s.reporting.StartCacheRefreshers(ctx)
}

// httpPathLabel returns a bounded label for HTTP metrics.
// We use the mux route pattern (e.g. "POST-/v1/chat/completions")
// instead of URL.Path so attacker-controlled unmatched paths cannot create
// unbounded metric cardinality. Dashes replace spaces so DogStatsD tags
// parse cleanly (spaces break tag parsing).
func httpPathLabel(route string) string {
	if route == "" {
		return "unmatched"
	}
	return strings.ReplaceAll(route, " ", "-")
}

// strconvItoa is a shim to avoid pulling strconv into every middleware file.
func strconvItoa(i int) string { return strconv.Itoa(i) }
