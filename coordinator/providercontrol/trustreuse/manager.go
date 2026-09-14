// Package trustreuse owns durable device evidence, revocation replay and
// coordinator-observed connection continuity. Signature verification and
// release-policy approval remain prerequisites supplied by the caller.
package trustreuse

import (
	"context"
	"log/slog"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// Registry exposes only the live identity, persistence and hard-untrust hooks
// needed by device-evidence lifecycle operations.
type Registry interface {
	GetProvider(string) *registry.Provider
	PersistProvider(*registry.Provider)
	SetHardUntrustHook(func(string))
}

type Config struct {
	DurableTrustReuse     bool
	TrustReuseJournalPath string
}

// Dependencies bind the existing coordinator services. MDMConfigured remains a
// live predicate because the MDM client is installed after server construction.
// Now defaults to the coordinator clock; callers must not mutate its captured
// state concurrently with an operation or the coverage worker.
type Dependencies struct {
	Registry           Registry
	Logger             *slog.Logger
	Now                func() time.Time
	MDMConfigured      func() bool
	NormalizeHash      func(value, field string) (string, error)
	SendStatus         func(*registry.Provider, registry.TrustLevel, string, string)
	RecordDecision     func(Decision, Reason)
	AfterCoverageSweep func()
}

// Manager keeps all reuse state and its synchronization private. The durable
// store is bound by Seed during startup, rather than looked up on every write.
type Manager struct {
	registry           Registry
	logger             *slog.Logger
	mdmConfigured      func() bool
	normalizeHash      func(string, string) (string, error)
	sendStatus         func(*registry.Provider, registry.TrustLevel, string, string)
	recordDecision     func(Decision, Reason)
	afterCoverageSweep func()

	cache                       *cache
	journal                     hardUntrustJournal
	revocationMu                sync.Mutex
	safetyMu                    sync.RWMutex
	safetySticky                bool
	safetyReplayBlocked         bool
	pendingHardUntrustKeyHashes map[string]int
	authorityMu                 sync.Mutex
	authority                   *trustAuthorityLock
	replayCtx                   context.Context
	replayCancel                context.CancelFunc
	replayMu                    sync.Mutex
	replayInFlight              map[string]struct{}

	// SE identity to the currently covered connection. Only coordinator
	// observations advance its durable watermark.
	coverageMu     sync.Mutex
	coverage       map[string]string
	coverageCtx    context.Context
	coverageCancel context.CancelFunc
}

func New(cfg Config, deps Dependencies) *Manager {
	s := &Manager{
		registry: deps.Registry, logger: deps.Logger,
		mdmConfigured: deps.MDMConfigured, normalizeHash: deps.NormalizeHash,
		sendStatus: deps.SendStatus, recordDecision: deps.RecordDecision,
		afterCoverageSweep: deps.AfterCoverageSweep,
		cache:              newCache(),
	}
	if deps.Now != nil {
		s.cache.now = deps.Now
	}
	if _, clampedDown := trustReuseReconnectGapFromEnv(); clampedDown {
		s.logger.Warn("EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP exceeds the 120s security ceiling; clamping DOWN",
			"requested", os.Getenv("EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP"),
			"allowance", maxTrustReuseReconnectGap,
			"reason", "a contiguous offline gap must stay below the RecoveryOS round-trip floor (Threat-Model T-036)",
		)
	}
	s.coverage = make(map[string]string)
	s.coverageCtx, s.coverageCancel = context.WithCancel(context.Background())
	saferun.Go(s.logger, "trustCoverageLoop", s.trustCoverageLoop)
	if cfg.DurableTrustReuse {
		journalPath := cfg.TrustReuseJournalPath
		if strings.TrimSpace(journalPath) == "" {
			journalPath = JournalPathFromEnv()
		}
		s.journal = newFileHardUntrustJournal(journalPath)
		s.pendingHardUntrustKeyHashes = make(map[string]int)
		s.replayCtx, s.replayCancel = context.WithCancel(context.Background())
		s.replayInFlight = make(map[string]struct{})
	}
	return s
}

// HasFreshRecord is the submit-time refresh classification. A fresh record
// alone never grants hardware trust; TryReuse still checks the signed response.
func (s *Manager) HasFreshRecord(seKey, serial string) bool {
	return s != nil && s.cache != nil && s.cache.hasFreshRecord(seKey, serial)
}

// Assessment is a bounded, read-only policy observation. It exposes no cache
// record, mutable state or grant authority.
type Assessment struct {
	Decision Decision
	Reason   Reason
}

func (s *Manager) Assess(input Input) Assessment {
	if s == nil || s.cache == nil {
		return Assessment{Reason: ReasonNoDeviceEvidence}
	}
	result := s.cache.decide(input)
	return Assessment{Decision: result.Decision, Reason: result.Reason}
}
