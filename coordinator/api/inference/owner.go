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
	"github.com/eigeninference/d-inference/coordinator/mediafetch"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type Dependencies struct {
	Registry    *registry.Registry
	Store       store.Store
	Ledger      *payments.Ledger
	Billing     *billing.Service
	Access      *access.Owner
	Observation *observation.Owner
	Geo         geo.Resolver
	Logger      *slog.Logger
}

type Config struct {
	ServiceReservations      bool
	FirstContentDeadlineBase time.Duration
	FirstContentSLAAccounts  []string
	MediaFetch               *mediafetch.Config
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
	firstContentSLAAccounts  map[string]struct{}
	firstContentSLAEmails    map[string]struct{}
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

	// One owner arbitrates active requests, late settlement, and cancellation.
	settlements           *settlementHolder
	settleGrace           time.Duration
	zombieCanceller       *zombieStreamCanceller
	hedgeGov              *hedgeGovernor
	serviceReservations   *serviceReservationManager
	modelTokenActive      sync.Map
	modelTokenRefunds     sync.Map
	modelTokenSettlements sync.Map
	chunkKeys             chunkKeyCache
	routingScanSem        chan struct{}
	routeLatencyMu        sync.Mutex
	routeLatencyEWMAMs    float64

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
	accounts, emails := firstContentAccountSelectors(cfg.FirstContentSLAAccounts)
	return &Owner{
		registry: d.Registry, store: d.Store, ledger: d.Ledger, billing: d.Billing,
		access: d.Access, observation: d.Observation, geoResolver: d.Geo, logger: d.Logger,
		mediaResolver:            mediafetch.NewResolver(mediaConfig, d.Logger),
		firstContentDeadlineBase: deadline, firstContentSLAAccounts: accounts, firstContentSLAEmails: emails,
		settlements: newSettlementHolder(), zombieCanceller: newZombieStreamCanceller(),
		hedgeGov: newHedgeGovernor(), serviceReservations: newServiceReservationManager(d.Store, cfg.ServiceReservations),
		routingScanSem: make(chan struct{}, DefaultRoutingConcurrency()),
	}
}

// SetBilling updates the service reference during application configuration.
func (s *Owner) SetBilling(service *billing.Service) { s.billing = service }

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
