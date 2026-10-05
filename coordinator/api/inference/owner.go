// Package inference owns the request lifecycle from admission through dispatch,
// streaming, cancellation, and final settlement. Provider transport delivers
// typed events to this same owner; it never settles requests independently.
package inference

import (
	"log/slog"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/geo"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/api/promptwork"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/backoff"
	cancellation "github.com/eigeninference/d-inference/coordinator/internal/inference/cancellation"
	chunkkeys "github.com/eigeninference/d-inference/coordinator/internal/inference/chunkkeys"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	inferhedge "github.com/eigeninference/d-inference/coordinator/internal/inference/hedge"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/promotions"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/reservations"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/responselimit"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/scangate"
	latesettlement "github.com/eigeninference/d-inference/coordinator/internal/inference/settlement"
	"github.com/eigeninference/d-inference/coordinator/mediafetch"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type Dependencies struct {
	Registry           *registry.Registry
	Store              store.Store
	Ledger             *payments.Ledger
	Billing            *billing.Service
	Access             *access.Owner
	Observation        *observation.Owner
	Geo                geo.Resolver
	Logger             *slog.Logger
	Cancellation       *cancellation.Controller
	Settlement         *latesettlement.Controller
	Promotions         *promotions.Engine
	Reservations       *reservations.Controller
	ScanGate           *scangate.Gate
	Backoff            *backoff.Policy
	ChunkKeys          *chunkkeys.Cache
	FirstContentPolicy *firstcontent.AccountPolicy
	HedgeGovernor      *inferhedge.Governor
}

type Config struct {
	ServiceReservations      bool
	FirstContentDeadlineBase time.Duration
	FirstContentSLAAccounts  []string
	MediaFetch               *mediafetch.Config
	// Non-positive values retain the safe defaults; limits cannot be disabled.
	NonStreamingResponseMaxBytes  int
	NonStreamingResponseMaxChunks int
}

type Owner struct {
	registry    *registry.Registry
	store       store.Store
	ledger      *payments.Ledger
	billing     *billing.Service
	access      *access.Owner
	observation *observation.Owner
	geoResolver geo.Resolver
	logger      *slog.Logger

	// These policies and limiters are configured before serving starts.
	ttftHardReject           bool
	firstContentDeadlineBase time.Duration
	firstContentPolicy       *firstcontent.AccountPolicy
	rejectModels             map[string]bool
	minDecodeTPS             float64
	servabilityGate          bool
	disableClientErrorStop   bool
	consumerTokenLimiter     *ratelimit.TokenLimiter
	serviceTokenLimiter      *ratelimit.TokenLimiter
	outputAdmissionEstimator *ratelimit.OutputAdmissionEstimator
	keyTokenLimiter          *ratelimit.KeyTokenLimiter
	coordinatorKey           *e2e.CoordinatorKey
	mediaResolver            *mediafetch.Resolver
	responseLimits           responselimit.Limits

	// One owner arbitrates active requests, late settlement, and cancellation.
	late         *latesettlement.Controller
	cancels      *cancellation.Controller
	hedgeGov     *inferhedge.Governor
	reservations *reservations.Controller
	promotions   *promotions.Engine
	chunkKeys    *chunkkeys.Cache
	scanGate     *scangate.Gate
	backoff      *backoff.Policy

	// Prompt-work resources and their read-only operational snapshots.
	promptArtifacts              *promptcontract.Provisioner
	promptContract               *promptcontract.Client
	promptWorkGate               *promptwork.Gate
	promptSupervisor             *promptcontract.Supervisor
	promptPreloader              *promptcontract.PreloadController
	exactCacheGaugeMu            sync.RWMutex
	exactCacheGaugeStatus        ExactCacheStatus
	exactCacheStatusCacheMu      sync.Mutex
	exactCacheStatusCache        ExactCacheStatus
	exactCacheStatusCacheExpires time.Time
}

func New(d Dependencies, cfg Config) *Owner {
	mediaConfig := mediafetch.ConfigFromEnv()
	if cfg.MediaFetch != nil {
		mediaConfig = *cfg.MediaFetch
	}
	deadline := cfg.FirstContentDeadlineBase
	if deadline <= 0 {
		deadline = defaultFirstContentDeadlineBase
	}
	accountPolicy := d.FirstContentPolicy
	if accountPolicy == nil {
		accountPolicy = &firstcontent.AccountPolicy{}
	}
	cancels := d.Cancellation
	if cancels == nil {
		cancels = &cancellation.Controller{Tracker: cancellation.NewTracker(nil)}
	}
	// An injected tracker shares the owner's actual collaborators; it cannot
	// substitute a different refund or observation path.
	cancels.Registry, cancels.Store = d.Registry, d.Store
	cancels.Observation, cancels.Logger = d.Observation, d.Logger
	late := d.Settlement
	if late == nil {
		late = &latesettlement.Controller{Holder: latesettlement.New()}
	}
	promos := d.Promotions
	if promos == nil {
		promos = &promotions.Engine{}
	}
	holds := d.Reservations
	if holds == nil {
		holds = &reservations.Controller{}
	}
	scans := d.ScanGate
	if scans == nil {
		scans = scangate.New(DefaultRoutingConcurrency())
	}
	retryBackoff := d.Backoff
	if retryBackoff == nil {
		retryBackoff = &backoff.Policy{}
	}
	retryBackoff.Bind(d.Registry, d.Observation)
	keys := d.ChunkKeys
	if keys == nil {
		keys = &chunkkeys.Cache{}
	}
	hedgeGov := d.HedgeGovernor
	if hedgeGov == nil {
		hedgeGov = inferhedge.NewGovernor()
	}
	s := &Owner{
		registry: d.Registry, store: d.Store, ledger: d.Ledger, billing: d.Billing,
		access: d.Access, observation: d.Observation, geoResolver: d.Geo, logger: d.Logger,
		mediaResolver:            mediafetch.NewResolver(mediaConfig, d.Logger),
		firstContentDeadlineBase: deadline, firstContentPolicy: accountPolicy,
		late: late, cancels: cancels, promotions: promos,
		responseLimits: responselimit.Limits{MaxBytes: cfg.NonStreamingResponseMaxBytes, MaxChunks: cfg.NonStreamingResponseMaxChunks},

		hedgeGov: hedgeGov, reservations: holds,
		scanGate: scans, backoff: retryBackoff, chunkKeys: keys,
	}
	accountPolicy.Bind(d.Store, cfg.FirstContentSLAAccounts, s.FirstContentDeadline)
	late.Refund, late.Outcome = s.refundReservedBalance, s.updateInferenceRouteOutcomeForPending
	promos.Bind(promotions.Dependencies{Store: d.Store, Logger: d.Logger, Unavailable: s.writeServiceUnavailable, IsService: s.isServiceConsumer, ProviderPricingKeys: providerPricingKeys})
	holds.Bind(reservations.Dependencies{Store: d.Store, Ledger: d.Ledger, Observation: d.Observation, Logger: d.Logger, Billing: d.Billing, Promotions: promos, IsService: s.isServiceConsumer, KeyCap: s.checkKeySpendCap, Unavailable: s.writeServiceUnavailable, Reject: s.recordBalanceRejection}, cfg.ServiceReservations)
	late.NoTerminal, late.ClientGone, late.Logger = s.NewMetrics().NoTerminal, s.NewMetrics().ClientGone, s.logger
	return s
}

// SetBilling updates the service reference during application configuration.
func (s *Owner) SetBilling(service *billing.Service) {
	s.billing = service
	s.reservations.SetBilling(service)
}

// CloseResources runs at the existing application shutdown boundary, before
// the observation owner flushes its final request records.
func (s *Owner) CloseResources() {
	if s.promptPreloader != nil {
		s.promptPreloader.Close()
	}
	if s.promptArtifacts != nil {
		s.promptArtifacts.Close()
	}
}
