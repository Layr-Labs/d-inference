// Package trust owns provider verification, attestation and trust persistence.
package trust

import (
	"context"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/api/releases"
	"github.com/eigeninference/d-inference/coordinator/apns"
	attestservice "github.com/eigeninference/d-inference/coordinator/appattest/service"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/profilesign"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type Hooks struct {
	RestoreProviderState func(context.Context, *registry.Provider, string, string, ...string) error
	ResolveBaseURL       func(*http.Request) string
}

type Dependencies struct {
	Registry    *registry.Registry
	Store       store.Store
	Access      *access.Owner
	Releases    *releases.Owner
	Observation *observation.Owner
	ReadCache   *readcache.Cache
	Logger      *slog.Logger
	Hooks       Hooks
}

type Config struct {
	AppAttest             AppAttestShadowConfig
	MDMScheduler          MDMSchedulerConfig
	MinProviderVersion    string
	DurableTrustReuse     bool
	TrustReuseJournalPath string
}

type Owner struct {
	registry                      *registry.Registry
	store                         store.Store
	access                        *access.Owner
	releases                      *releases.Owner
	observation                   *observation.Owner
	readCache                     *readcache.Cache
	logger                        *slog.Logger
	hooks                         Hooks
	appAttestShadow               AppAttestShadowConfig
	appAttest                     *attestservice.Service
	appAttestOnce                 sync.Once
	challengeInterval             time.Duration
	skipChallenge                 bool
	allowDuplicateProviderSerials bool
	minProviderVersion            string
	mdmClient                     *mdm.Client
	mdmScheduler                  *mdmVerificationScheduler
	mdmSchedulerConfig            MDMSchedulerConfig
	mdmWebhookSecret              string
	profileSigner                 *profilesign.Signer
	codeAttestor                  apns.CodeIdentityAttestor
	codeResumeSender              func(string, protocol.CodeAttestationResumeChallenge) error
	codeResumeBeforeIdentityCheck func()
	codeResumeFallbackBeforeAPNs  func()
	codeAttestThrottle            *codeAttestThrottle
	trustReuseCache               *trustReuseCache
	trustReuseJournal             hardUntrustJournal
	trustRevocationMu             sync.Mutex
	trustSafetyMu                 sync.RWMutex
	trustSafetySticky             bool
	trustSafetyReplayBlocked      bool
	pendingHardUntrustKeyHashes   map[string]int
	trustAuthorityMu              sync.Mutex
	trustAuthority                *trustAuthorityLock
	trustReplayCtx                context.Context
	trustReplayCancel             context.CancelFunc
	trustReplayMu                 sync.Mutex
	trustReplayInFlight           map[string]struct{}
	trustCoverageMu               sync.Mutex
	trustCoverage                 map[string]string
	trustCoverageCtx              context.Context
	trustCoverageCancel           context.CancelFunc
}

func New(d Dependencies, cfg Config) *Owner {
	s := &Owner{registry: d.Registry, store: d.Store, access: d.Access, releases: d.Releases,
		observation: d.Observation, readCache: d.ReadCache, logger: d.Logger, hooks: d.Hooks,
		appAttestShadow: cfg.AppAttest, mdmSchedulerConfig: cfg.MDMScheduler,
		minProviderVersion: strings.TrimSpace(cfg.MinProviderVersion),
		codeAttestThrottle: newCodeAttestThrottle(), trustReuseCache: newTrustReuseCache(),
		trustCoverage: make(map[string]string)}
	s.trustCoverageCtx, s.trustCoverageCancel = context.WithCancel(context.Background())
	if cfg.DurableTrustReuse {
		journalPath := cfg.TrustReuseJournalPath
		if strings.TrimSpace(journalPath) == "" {
			journalPath = ResolveTrustReuseRevocationJournalPath()
		}
		s.trustReuseJournal = newFileHardUntrustJournal(journalPath)
		s.pendingHardUntrustKeyHashes = make(map[string]int)
		s.trustReplayCtx, s.trustReplayCancel = context.WithCancel(context.Background())
		s.trustReplayInFlight = make(map[string]struct{})
	}
	return s
}

func (s *Owner) SetMinProviderVersion(v string) { s.minProviderVersion = strings.TrimSpace(v) }
func (s *Owner) MinProviderVersion() string     { return s.minProviderVersion }
func (s *Owner) BelowMinProviderVersion(version string) bool {
	return s.minProviderVersion != "" && (version == "" || releases.SemverLess(version, s.minProviderVersion))
}
func (s *Owner) AppAttestServing() bool {
	return s.appAttestShadow.ServingEnabled && s.appAttestShadow.Environment == "production"
}

func VersionMetricTag(version string) string {
	if version == "" {
		return "version:unknown"
	}
	return "version:" + version
}
