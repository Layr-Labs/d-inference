// Package trust owns provider verification, attestation and trust persistence.
package trust

import (
	"context"
	"log/slog"
	"net/http"
	"strings"
	"sync"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/api/releases"
	attestservice "github.com/eigeninference/d-inference/coordinator/appattest/service"
	trustauthority "github.com/eigeninference/d-inference/coordinator/internal/provider/authority"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/challenge"
	codeattest "github.com/eigeninference/d-inference/coordinator/internal/provider/codeidentity"
	trustcoverage "github.com/eigeninference/d-inference/coordinator/internal/provider/coverage"
	deviceverification "github.com/eigeninference/d-inference/coordinator/internal/provider/deviceverification"
	codeidentity "github.com/eigeninference/d-inference/coordinator/internal/provider/identity"
	coderesume "github.com/eigeninference/d-inference/coordinator/internal/provider/identity/resume"
	trustjournal "github.com/eigeninference/d-inference/coordinator/internal/provider/journal"
	trustreuse "github.com/eigeninference/d-inference/coordinator/internal/provider/reuse"
	"github.com/eigeninference/d-inference/coordinator/profilesign"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type Hooks struct {
	RestoreProviderState func(context.Context, *registry.Provider, string, string, ...string) error
	ResolveBaseURL       func(*http.Request) string
}

type Dependencies struct {
	Registry           *registry.Registry
	Store              store.Store
	Access             *access.Owner
	Releases           *releases.Owner
	Observation        *observation.Owner
	ReadCache          *readcache.Cache
	Logger             *slog.Logger
	Hooks              Hooks
	TrustReuseCache    *trustreuse.Cache
	TrustReuseJournal  trustjournal.Journal
	CodeAttestThrottle *codeidentity.Throttle
	ResumeTransport    coderesume.Transport
	ResumeRecovery     coderesume.Recovery
	MDMBackend         *deviceverification.Backend
}

type Config struct {
	AppAttest             AppAttestShadowConfig
	MDMScheduler          MDMSchedulerConfig
	MinProviderVersion    string
	DurableTrustReuse     bool
	TrustReuseJournalPath string
}

type Owner struct {
	*trustauthority.Service
	*codeattest.Controller
	*deviceverification.Verifier
	*challenge.Engine
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
	challengeSettings             challenge.Configuration
	allowDuplicateProviderSerials bool
	verificationBackend           *deviceverification.Backend
	mdmSchedulerConfig            MDMSchedulerConfig
	mdmWebhookSecret              string
	profileSigner                 *profilesign.Signer
	codeAttestThrottle            *codeidentity.Throttle
	trustCoverageCtx              context.Context
	trustCoverageCancel           context.CancelFunc
}

func New(d Dependencies, cfg Config) *Owner {
	s := &Owner{registry: d.Registry, store: d.Store, access: d.Access, releases: d.Releases,
		observation: d.Observation, readCache: d.ReadCache, logger: d.Logger, hooks: d.Hooks,
		appAttestShadow: cfg.AppAttest, mdmSchedulerConfig: cfg.MDMScheduler,
		challengeSettings:  challenge.Configuration{MinProviderVersion: strings.TrimSpace(cfg.MinProviderVersion)},
		codeAttestThrottle: newCodeAttestThrottle()}
	if d.CodeAttestThrottle != nil {
		s.codeAttestThrottle = d.CodeAttestThrottle
	}
	s.trustCoverageCtx, s.trustCoverageCancel = context.WithCancel(context.Background())
	s.verificationBackend = d.MDMBackend
	if s.verificationBackend == nil {
		s.verificationBackend = &deviceverification.Backend{}
	}
	cache := d.TrustReuseCache
	if cache == nil {
		cache = trustreuse.New()
	}
	journal := d.TrustReuseJournal
	if cfg.DurableTrustReuse && journal == nil {
		journalPath := cfg.TrustReuseJournalPath
		if strings.TrimSpace(journalPath) == "" {
			journalPath = trustjournal.ResolveTrustReuseRevocationJournalPath()
		}
		journal = trustjournal.NewFile(journalPath)
	}
	s.Service = trustauthority.New(trustauthority.Dependencies{
		Registry: d.Registry, Store: d.Store, Cache: cache, Journal: journal,
		Coverage: trustcoverage.New(d.Registry, d.Logger, cache),
		Logger:   d.Logger, Observation: d.Observation,
		MDMConfigured: func() bool {
			return s.verificationBackend.Client != nil
		},
		SendTrustStatus: s.sendTrustStatus,
	})
	s.Controller = codeattest.New(codeattest.Dependencies{
		Registry: d.Registry, Store: d.Store, Releases: d.Releases,
		Observation: d.Observation, Logger: d.Logger, Throttle: s.codeAttestThrottle,
		ResumeTransport: d.ResumeTransport, ResumeRecovery: d.ResumeRecovery,
	})
	s.Verifier = deviceverification.New(deviceverification.Dependencies{
		Registry: d.Registry, Store: d.Store, Observation: d.Observation, Logger: d.Logger,
		Backend: s.verificationBackend, Authority: s.Service, SendTrustStatus: s.sendTrustStatus,
	})
	s.Engine = challenge.NewEngine(challenge.Dependencies{
		Registry: d.Registry, Releases: d.Releases, Observation: d.Observation, Logger: d.Logger,
		Configuration: &s.challengeSettings,
		Policy: challenge.NewPolicy(challenge.PolicyDependencies{
			Registry: d.Registry, Releases: d.Releases, Observation: d.Observation, Logger: d.Logger,
			Configuration: &s.challengeSettings, SendTrustStatus: s.sendTrustStatus,
		}),
		Authority: s.Service, Identity: s.Controller, Device: s.Verifier, Backend: s.verificationBackend,
		SendTrustStatus: s.sendTrustStatus,
	})
	return s
}

func (s *Owner) SetMinProviderVersion(v string) {
	s.challengeSettings.MinProviderVersion = strings.TrimSpace(v)
}
func (s *Owner) MinProviderVersion() string { return s.challengeSettings.MinProviderVersion }
func (s *Owner) BelowMinProviderVersion(version string) bool {
	return s.challengeSettings.BelowMinProviderVersion(version)
}
func (s *Owner) AppAttestServing() bool {
	return s.appAttestShadow.ServingEnabled && s.appAttestShadow.Environment == "production"
}
