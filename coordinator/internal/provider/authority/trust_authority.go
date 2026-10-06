package authority

import (
	"context"
	"log/slog"
	"sync"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	trustcoverage "github.com/eigeninference/d-inference/coordinator/internal/provider/coverage"
	trustjournal "github.com/eigeninference/d-inference/coordinator/internal/provider/journal"
	trustreuse "github.com/eigeninference/d-inference/coordinator/internal/provider/reuse"
	trustguard "github.com/eigeninference/d-inference/coordinator/internal/provider/trustguard"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type Dependencies struct {
	Registry         *registry.Registry
	Store            trustreuse.Store
	Cache            *trustreuse.Cache
	Coverage         *trustcoverage.Tracker
	Journal          trustjournal.Journal
	Logger           *slog.Logger
	Observation      *observation.Owner
	MDMConfigured    func() bool
	LegacyMDMAllowed func(*registry.Provider) bool
	SendTrustStatus  func(*registry.Provider, registry.TrustLevel, string, string)
}

// trustAuthority serializes durable revocations and grants against one cache.
// The cache and journal are constructor dependencies shared with startup and
// coverage; none of the authority's fencing or safety-latch state escapes.
type Service struct {
	*trustguard.Guard
	*trustcoverage.Tracker
	registry            *registry.Registry
	store               trustreuse.Store
	logger              *slog.Logger
	observation         *observation.Owner
	mdmConfigured       func() bool
	legacyMDMAllowed    func(*registry.Provider) bool
	sendTrustStatus     func(*registry.Provider, registry.TrustLevel, string, string)
	trustReuseCache     *trustreuse.Cache
	trustReuseJournal   trustjournal.Journal
	trustRevocationMu   sync.Mutex
	trustAuthorityMu    sync.Mutex
	authorityLock       *trustjournal.AuthorityLock
	trustReplayCtx      context.Context
	trustReplayCancel   context.CancelFunc
	trustReplayMu       sync.Mutex
	trustReplayInFlight map[string]struct{}
}

func New(d Dependencies) *Service {
	s := &Service{
		Guard:    trustguard.New(d.Logger, d.Journal != nil),
		Tracker:  d.Coverage,
		registry: d.Registry, store: d.Store, logger: d.Logger,
		observation: d.Observation, mdmConfigured: d.MDMConfigured,
		legacyMDMAllowed: d.LegacyMDMAllowed,
		sendTrustStatus:  d.SendTrustStatus,
		trustReuseCache:  d.Cache, trustReuseJournal: d.Journal,
	}
	if d.Journal != nil {
		s.trustReplayCtx, s.trustReplayCancel = context.WithCancel(context.Background())
		s.trustReplayInFlight = make(map[string]struct{})
	}
	return s
}

func (s *Service) StopReplay() {
	if s != nil && s.trustReplayCancel != nil {
		s.trustReplayCancel()
	}
}
