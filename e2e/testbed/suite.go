package testbed

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/e2e/testbed/deps"
)

var ErrProviderIneligible = errors.New("provider lacks expected testbed capabilities")

type Suite struct {
	providerAttempts []*Provider

	Ctx    context.Context
	Logger *slog.Logger
	Config SuiteConfig

	Pg          *deps.PostgresLifecycle
	PgStore     store.Store
	Coordinator *Coordinator
	Providers   []*Provider
	Users       []UserAccount

	// privacyMu guards privacyAtRegistration, written once during Start and
	// read afterwards from test goroutines.
	privacyMu sync.Mutex
	// privacyAtRegistration snapshots every provider's self-reported
	// privacy_capabilities block exactly as it arrived over the wire, taken
	// immediately BEFORE waitForProviderRegistration force-trusts the fleet.
	// Force-trust overwrites most of that block with synthetic `true`s and
	// materialises an empty one when the provider sent none, so an assertion
	// made on the live registry copy after Start cannot fail. Tests that need
	// the provider's actual claim read it through ReportedPrivacyCapabilities.
	// A key is present for every provider that registered; a nil value means
	// that provider reported no block at all.
	privacyAtRegistration map[string]*protocol.PrivacyCapabilities
	targetNonce           string
}

func NewSuite(cfg SuiteConfig) *Suite {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))

	if os.Getenv("DARKBLOOM_REPO_ROOT") == "" {
		if cwd, err := os.Getwd(); err == nil {
			if root, rootErr := findRepositoryRoot(cwd); rootErr == nil {
				_ = os.Setenv("DARKBLOOM_REPO_ROOT", root)
			}
		}
	}

	if len(cfg.ModelSpecs) == 0 {
		cfg.ModelSpecs = []ModelSpec{{ModelID: resolveModelID(""), NumProviders: 1}}
	}
	for i := range cfg.ModelSpecs {
		if len(cfg.ModelSpecs[i].ModelIDs) > 0 {
			for j := range cfg.ModelSpecs[i].ModelIDs {
				cfg.ModelSpecs[i].ModelIDs[j] = resolveModelID(cfg.ModelSpecs[i].ModelIDs[j])
			}
		} else {
			cfg.ModelSpecs[i].ModelID = resolveModelID(cfg.ModelSpecs[i].ModelID)
		}
		if cfg.ModelSpecs[i].NumProviders <= 0 {
			cfg.ModelSpecs[i].NumProviders = 1
		}
	}
	if cfg.NumUsers <= 0 {
		cfg.NumUsers = 1
	}
	if cfg.QueueCapacity <= 0 {
		cfg.QueueCapacity = 100
	}
	if cfg.QueueTimeout <= 0 {
		cfg.QueueTimeout = 120 * time.Second
	}
	if cfg.FirstContentDeadlineBase <= 0 {
		cfg.FirstContentDeadlineBase = ProductionFirstContentDeadlineBase
	}
	if cfg.SeedBalance <= 0 {
		cfg.SeedBalance = 100_000_000
	}

	return &Suite{
		Logger: logger,
		Config: cfg,
	}
}

func resolveModelID(modelID string) string {
	if modelID != "" {
		return modelID
	}
	if env := os.Getenv("TESTBED_MODEL_ID"); env != "" {
		return env
	}
	// v0.7.5 one-engine: only CBv2-adapted checkpoints are servable
	// (DefaultTestModelID — gpt-oss-20b unless DARKBLOOM_TESTBED_MODEL
	// overrides).
	return DefaultTestModelID()
}

func (s *Suite) PrimaryModelID() string {
	return s.Config.PrimaryModelID()
}

func (s *Suite) Start(ctx context.Context) (err error) {
	s.Ctx = ctx
	if err := validateProviderTargets(s.Config.ProviderTargets, s.Config.TotalProviders()); err != nil {
		return err
	}
	if s.Config.ProviderTargets != nil {
		if s.Config.ProviderRelay == nil || !s.Config.UseMemoryStore {
			return fmt.Errorf("owned targets require the loopback relay and isolated memory store")
		}
		if s.Config.PrefixCacheMode != "off" && s.Config.PrefixCacheMode != "ssd" {
			return fmt.Errorf("owned targets require explicit cache mode")
		}
		nonce := make([]byte, 16)
		if _, err := rand.Read(nonce); err != nil {
			return err
		}
		s.targetNonce = hex.EncodeToString(nonce)
	}

	defer func() {
		if err != nil {
			err = errors.Join(err, s.StopAndWait())
		}
	}()

	if err = s.startStore(); err != nil {
		return err
	}
	if err = s.createUserPool(); err != nil {
		return err
	}
	if err = s.startCoordinator(); err != nil {
		return err
	}
	if err = s.startProviders(); err != nil {
		return err
	}
	if err = s.waitForProviderRegistration(3 * time.Minute); err != nil {
		return err
	}
	// Built-backend assertion: when the lane declares an expected KV backend
	// (DARKBLOOM_TESTBED_EXPECT_KV_BACKEND or SuiteConfig.ExpectKVBackend),
	// refuse to come up until every provider slot proves the engine it
	// actually constructed matches. See kv_expectation.go.
	err = s.verifyKVBackendExpectation()
	return err
}

func (s *Suite) Stop() { _ = s.StopAndWait() }

func (s *Suite) StopAndWait() error {
	var result error
	seen := make(map[*Provider]bool)
	for _, providers := range [][]*Provider{s.Providers, s.providerAttempts} {
		for _, p := range providers {
			if !seen[p] {
				seen[p] = true
				result = errors.Join(result, p.StopAndWait())
			}
		}
	}
	if s.Config.ProviderRelay != nil {
		s.Config.ProviderRelay.Close()
	}
	if s.Coordinator != nil {
		result = errors.Join(result, s.Coordinator.Stop())
	}
	if s.Pg != nil {
		s.Pg.Stop()
	}
	return result
}
