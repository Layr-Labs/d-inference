package testbed

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/e2e/testbed/deps"
)

type tcpListener struct {
	inner   net.Listener
	port    int
	baseURL string
}

func netListen() (*tcpListener, error) {
	inner, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	port := inner.Addr().(*net.TCPAddr).Port
	return &tcpListener{
		inner:   inner,
		port:    port,
		baseURL: "http://127.0.0.1:" + strconv.Itoa(port),
	}, nil
}

func execCommandContext(ctx context.Context, name string, args ...string) *exec.Cmd {
	return exec.CommandContext(ctx, name, args...)
}

type Suite struct {
	Ctx    context.Context
	Logger *slog.Logger
	Config SuiteConfig

	Pg          *deps.PostgresLifecycle
	PgStore     store.Store
	Coordinator *Coordinator
	Providers   []*Provider
	Users       []UserAccount
}

type Coordinator struct {
	Server   *api.Server
	Registry *registry.Registry
	baseURL  string
	port     int

	httpServer *http.Server
	cancel     context.CancelFunc
}

type Provider struct {
	BinaryPath    string
	Logger        *slog.Logger
	ProviderIndex int
	AuthDir       string
	// StateDir is a per-instance temp dir that holds the provider's
	// persisted state files (daemon-state.json, loaded-models.json).
	// Without it every testbed provider shares the real
	// ~/.darkbloom/loaded-models.json, so provider N+1 startup-preloads
	// (and self-tests) whatever provider N was serving — cross-test
	// state leakage that does not represent a fresh provider boot.
	StateDir string

	cmd    *os.Process
	cancel context.CancelFunc
	done   chan struct{}

	// generatedConfig holds the provider TOML this instance wrote into
	// StateDir. Empty when no KV-backend / concurrency knob was set, which is
	// the default and launches with no --config at all.
	generatedConfig string
	// canonicalConfigExisted records whether ~/.config/darkbloom/provider.toml
	// was present at launch. The provider copies a --config file there when it
	// is missing; Stop undoes that copy so a testbed TOML never becomes the
	// machine's default config.
	canonicalConfigExisted bool
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
	defer func() {
		if err != nil {
			s.Stop()
		}
	}()

	if err = s.startPostgres(); err != nil {
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
	err = s.waitForProviderRegistration(3 * time.Minute)
	return err
}

func (s *Suite) Stop() {
	for _, p := range s.Providers {
		p.Stop()
	}
	if s.Coordinator != nil {
		s.Coordinator.Stop()
	}
	if s.Pg != nil {
		s.Pg.Stop()
	}
}

func (s *Suite) startPostgres() error {
	if s.Config.UseMemoryStore {
		s.PgStore = NewMemoryStore()
		if err := s.PgStore.Credit("admin", s.Config.SeedBalance, store.LedgerDeposit, "test-seed"); err != nil {
			return fmt.Errorf("seed memory balance: %w", err)
		}
		s.Logger.Info("using in-memory testbed store")
		return nil
	}

	s.Pg = deps.NewPostgresLifecycle(s.Logger, 0)
	if err := s.Pg.Start(s.Ctx); err != nil {
		return fmt.Errorf("postgres: %w", err)
	}
	s.Logger.Info("postgres started", "url", s.Pg.DatabaseURL)

	var err error
	s.PgStore, err = NewPostgresStore(s.Ctx, s.Pg.DatabaseURL)
	if err != nil {
		return fmt.Errorf("postgres store: %w", err)
	}
	if err := s.PgStore.Credit("admin", s.Config.SeedBalance, store.LedgerDeposit, "test-seed"); err != nil {
		return fmt.Errorf("seed balance: %w", err)
	}
	return nil
}

func (s *Suite) createUserPool() error {
	for i := 0; i < s.Config.NumUsers; i++ {
		accountID := fmt.Sprintf("testbed-user-%d", i)
		apiKey, err := s.PgStore.CreateKeyForAccount(accountID)
		if err != nil {
			return fmt.Errorf("create key for user %d: %w", i, err)
		}
		if err := s.PgStore.Credit(accountID, s.Config.SeedBalance, store.LedgerDeposit, "test-seed"); err != nil {
			return fmt.Errorf("credit user %d: %w", i, err)
		}
		s.Users = append(s.Users, UserAccount{
			AccountID: accountID,
			APIKey:    apiKey,
		})
	}
	s.Logger.Info("user pool created", "count", len(s.Users))
	return nil
}

func (s *Suite) startCoordinator() error {
	reg := registry.New(s.Logger)
	reg.MinTrustLevel = registry.TrustLevel(TrustNone)

	var catalog []registry.CatalogEntry
	for _, id := range s.Config.AllModelIDs() {
		catalog = append(catalog, registry.CatalogEntry{ID: id})
	}
	reg.SetModelCatalog(catalog)

	srv := api.NewServer(reg, s.PgStore, api.ServerConfig{}, s.Logger)
	srv.SetAdminKey("testbed-admin-key")
	srv.SetRuntimeManifest(&api.RuntimeManifest{})
	srv.SetChallengeInterval(1 * time.Hour)
	srv.SetSkipChallenge(true)
	srv.SetAllowDuplicateProviderSerialsForTesting(true)

	ledger := payments.NewLedger(s.PgStore)
	billingSvc := billing.NewService(s.PgStore, ledger, s.Logger, billing.Config{MockMode: true})
	srv.SetBilling(billingSvc)

	reg.SetQueue(registry.NewRequestQueue(s.Config.QueueCapacity, s.Config.QueueTimeout))

	s.Coordinator = &Coordinator{
		Server:   srv,
		Registry: reg,
	}

	return s.Coordinator.Start(s.Ctx, s.Logger)
}

func (s *Suite) startProviders() error {
	binaryPath, err := BuildProvider(s.Ctx, s.Logger)
	if err != nil {
		return fmt.Errorf("build provider: %w", err)
	}

	providerIdx := 0
	for _, spec := range s.Config.ModelSpecs {
		modelIDs := spec.IDs()
		for j := 0; j < spec.NumProviders; j++ {
			if providerIdx > 0 {
				time.Sleep(500 * time.Millisecond)
			}
			p := &Provider{
				BinaryPath:    binaryPath,
				Logger:        s.Logger.With("provider_index", providerIdx, "models", strings.Join(modelIDs, ",")),
				ProviderIndex: providerIdx,
			}
			authDir, authTokenPath, err := s.prepareProviderAuth(providerIdx)
			if err != nil {
				return fmt.Errorf("prepare provider auth %d: %w", providerIdx, err)
			}
			p.AuthDir = authDir
			if err := p.Start(s.Ctx, s.Coordinator.BaseURL(), ProviderConfig{
				ModelIDs:                   modelIDs,
				TrustLevel:                 TrustNone,
				AuthTokenPath:              authTokenPath,
				EnableEphemeralPrefixCache: s.Config.EnableEphemeralPrefixCache,
				KVBackend:                  s.Config.KVBackend,
				MaxConcurrent:              s.Config.MaxConcurrent,
			}); err != nil {
				_ = os.RemoveAll(authDir)
				return fmt.Errorf("start provider %d (%s): %w", providerIdx, strings.Join(modelIDs, ","), err)
			}
			s.Providers = append(s.Providers, p)
			providerIdx++
		}
	}
	return nil
}

func (s *Suite) prepareProviderAuth(providerIdx int) (string, string, error) {
	rawToken := fmt.Sprintf("testbed-provider-token-%d-%d", providerIdx, time.Now().UnixNano())
	tokenHash := sha256.Sum256([]byte(rawToken))
	accountID := fmt.Sprintf("testbed-provider-%d", providerIdx)
	if err := s.PgStore.CreateProviderToken(&store.ProviderToken{
		TokenHash: hex.EncodeToString(tokenHash[:]),
		AccountID: accountID,
		Label:     fmt.Sprintf("testbed-provider-%d", providerIdx),
		Active:    true,
		CreatedAt: time.Now(),
	}); err != nil {
		return "", "", err
	}

	authDir, err := os.MkdirTemp("", fmt.Sprintf("darkbloom-testbed-provider-%d-", providerIdx))
	if err != nil {
		return "", "", err
	}
	tokenDir := filepath.Join(authDir, ".darkbloom")
	if err := os.MkdirAll(tokenDir, 0700); err != nil {
		_ = os.RemoveAll(authDir)
		return "", "", err
	}
	authTokenPath := filepath.Join(tokenDir, "auth_token")
	if err := os.WriteFile(authTokenPath, []byte(rawToken+"\n"), 0600); err != nil {
		_ = os.RemoveAll(authDir)
		return "", "", err
	}
	return authDir, authTokenPath, nil
}

func (s *Suite) waitForProviderRegistration(timeout time.Duration) error {
	expectedCount := s.Config.TotalProviders()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if s.Coordinator.Registry.ProviderCount() >= expectedCount {
			break
		}
		time.Sleep(1 * time.Second)
	}
	if s.Coordinator.Registry.ProviderCount() < expectedCount {
		return fmt.Errorf("only %d/%d providers registered after %v", s.Coordinator.Registry.ProviderCount(), expectedCount, timeout)
	}
	s.Logger.Info("providers registered", "count", s.Coordinator.Registry.ProviderCount())

	time.Sleep(3 * time.Second)

	// Force-trust all providers and link them to a user account so the
	// payout destination check passes when billing is enabled.
	s.Coordinator.Registry.ForEachProvider(func(p *registry.Provider) {
		p.Mu().Lock()
		p.Status = registry.StatusOnline
		p.TrustLevel = registry.TrustSelfSigned
		p.ChallengeVerifiedSIP = true
		p.LastChallengeVerified = time.Now()
		p.FailedChallenges = 0
		p.RuntimeVerified = true
		p.RuntimeManifestChecked = true
		if p.PrivacyCapabilities == nil {
			p.PrivacyCapabilities = &protocol.PrivacyCapabilities{}
		}
		p.PrivacyCapabilities.TextBackendInprocess = true
		p.PrivacyCapabilities.TextProxyDisabled = true
		p.PrivacyCapabilities.PythonRuntimeLocked = true
		p.PrivacyCapabilities.DangerousModulesBlocked = true
		p.PrivacyCapabilities.AntiDebugEnabled = true
		p.PrivacyCapabilities.CoreDumpsDisabled = true
		p.PrivacyCapabilities.EnvScrubbed = true
		if p.AccountID == "" && len(s.Users) > 0 {
			p.AccountID = s.Users[0].AccountID
		}
		p.Mu().Unlock()
	})
	s.Logger.Info("providers force-trusted for testing")

	return nil
}

func (c *Coordinator) Start(ctx context.Context, logger *slog.Logger) error {
	listener, err := netListen()
	if err != nil {
		return fmt.Errorf("listen: %w", err)
	}
	c.port = listener.port
	c.baseURL = listener.baseURL

	ctx, c.cancel = context.WithCancel(ctx)

	c.httpServer = &http.Server{
		Handler:      c.Server.Handler(),
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 0,
		IdleTimeout:  120 * time.Second,
	}

	go func() {
		if err := c.httpServer.Serve(listener.inner); err != nil && err != http.ErrServerClosed {
			logger.Error("coordinator http server error", "error", err)
		}
	}()

	c.Registry.StartEvictionLoop(ctx, 1*time.Hour)
	logger.Info("test coordinator started", "port", c.port, "base_url", c.baseURL)
	return nil
}

func (c *Coordinator) BaseURL() string {
	return c.baseURL
}

func (c *Coordinator) Stop() error {
	if c.cancel != nil {
		c.cancel()
	}
	if c.httpServer != nil {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := c.httpServer.Shutdown(shutdownCtx); err != nil {
			return fmt.Errorf("coordinator shutdown: %w", err)
		}
	}
	return nil
}

func (p *Provider) Start(ctx context.Context, coordinatorURL string, cfg ProviderConfig) error {
	binaryPath := p.BinaryPath
	if binaryPath == "" {
		binaryPath = findProviderBinary()
	}
	if binaryPath == "" {
		return fmt.Errorf("provider binary not found (set DARKBLOOM_PROVIDER_BINARY or ensure 'darkbloom' is in PATH)")
	}
	p.BinaryPath = binaryPath

	ctx, p.cancel = context.WithCancel(ctx)

	wsURL := coordinatorURL
	wsURL = strings.Replace(wsURL, "https://", "wss://", 1)
	wsURL = strings.Replace(wsURL, "http://", "ws://", 1)
	if !strings.HasSuffix(wsURL, "/ws/provider") {
		wsURL += "/ws/provider"
	}

	args := []string{"start", "--foreground", "--coordinator-url", wsURL}
	if len(cfg.ModelIDs) > 0 {
		for _, modelID := range cfg.ModelIDs {
			args = append(args, "--model", modelID)
		}
	} else if cfg.ModelID != "" {
		args = append(args, "--model", cfg.ModelID)
	}

	// Isolate the provider's persisted state per testbed instance. The
	// provider defaults these files to ~/.darkbloom/, which is shared by
	// every provider process on the machine (and across CI runs on a
	// persistent runner): test 1's provider would persist its loaded-model
	// set there, and test 2's freshly-booted provider would then
	// startup-preload + self-test it — behavior a fresh boot must not have.
	if p.StateDir == "" {
		stateDir, err := os.MkdirTemp("",
			"darkbloom-testbed-state-"+strconv.Itoa(p.ProviderIndex)+"-")
		if err != nil {
			return fmt.Errorf("create provider state dir: %w", err)
		}
		p.StateDir = stateDir
	}

	// The KV backend and the per-slot concurrency cap have no env-var or CLI
	// equivalent (DARKBLOOM_CBV2_PAGED_KV can only force paged OFF), so
	// selecting them means handing the provider a TOML. Unset knobs render no
	// file and add no argument: the default launch stays byte-identical.
	generated, err := BuildProviderTOML(cfg, p.ProviderIndex)
	if err != nil {
		return fmt.Errorf("provider %d config: %w", p.ProviderIndex, err)
	}
	if generated != "" {
		configPath := filepath.Join(p.StateDir, "provider.toml")
		if err := os.WriteFile(configPath, []byte(generated), 0600); err != nil {
			return fmt.Errorf("write provider config: %w", err)
		}
		args = append(args, "--config", configPath)
		p.generatedConfig = generated
		if canonical := canonicalProviderConfigPath(); canonical != "" {
			_, statErr := os.Stat(canonical)
			p.canonicalConfigExisted = statErr == nil
		}
		p.Logger.Info("provider config written",
			"path", configPath,
			"kv_backend", ResolveKVBackend(cfg.KVBackend),
			"max_concurrent", ResolveMaxConcurrent(cfg.MaxConcurrent))
	}

	cmd := execCommandContext(ctx, p.BinaryPath, args...)
	cmd.Stdout = &logWriter{logger: p.Logger, prefix: "provider:stdout"}
	cmd.Stderr = &logWriter{logger: p.Logger, prefix: "provider:stderr"}
	cmd.Env = append(os.Environ(),
		"DARKBLOOM_PID_FILE="+filepath.Join(p.StateDir, "provider.pid"),
		"DARKBLOOM_NO_UPDATE_CHECK=1",
		"DARKBLOOM_STATE_FILE="+filepath.Join(p.StateDir, "daemon-state.json"),
		"DARKBLOOM_LOADED_MODELS_FILE="+filepath.Join(p.StateDir, "loaded-models.json"),
	)
	if cfg.AuthTokenPath != "" {
		cmd.Env = append(cmd.Env, "DARKBLOOM_AUTH_TOKEN_PATH="+cfg.AuthTokenPath)
	}
	if cfg.EnableEphemeralPrefixCache {
		cmd.Env = append(
			cmd.Env,
			"DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL=1",
			"DARKBLOOM_PREFIX_CACHE_TEST_ROOT="+filepath.Join(p.StateDir, "prefix-cache"),
		)
	}

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start provider: %w", err)
	}

	p.cmd = cmd.Process
	p.done = make(chan struct{})
	p.Logger.Info("provider started", "binary", p.BinaryPath, "pid", p.cmd.Pid)

	go func(done chan struct{}) {
		defer close(done)
		state, err := cmd.Process.Wait()
		if err != nil {
			p.Logger.Warn("provider process wait failed", "error", err)
			return
		}
		if state != nil && state.ExitCode() >= 0 {
			p.Logger.Warn("provider process exited", "exit_code", state.ExitCode())
		}
	}(p.done)

	return nil
}

func (p *Provider) Stop() {
	if p.cmd != nil {
		_ = p.cmd.Signal(os.Interrupt)
		select {
		case <-p.done:
		case <-time.After(10 * time.Second):
			_ = p.cmd.Kill()
			select {
			case <-p.done:
			case <-time.After(time.Second):
			}
		}
		p.cmd = nil
		p.done = nil
	}
	if p.cancel != nil {
		p.cancel()
		p.cancel = nil
	}
	if p.AuthDir != "" {
		_ = os.RemoveAll(p.AuthDir)
	}
	if p.StateDir != "" {
		_ = os.RemoveAll(p.StateDir)
	}
	removeMigratedTestbedConfig(p.generatedConfig, p.canonicalConfigExisted)
	p.Logger.Info("provider stopped")
}
