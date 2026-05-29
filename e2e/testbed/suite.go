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

	cmd    *os.Process
	cancel context.CancelFunc
}

func NewSuite(cfg SuiteConfig) *Suite {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))

	if os.Getenv("DARKBLOOM_REPO_ROOT") == "" {
		if cwd, err := os.Getwd(); err == nil {
			os.Setenv("DARKBLOOM_REPO_ROOT", cwd+"/../..")
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
	return "mlx-community/Qwen3.5-0.8B-MLX-4bit"
}

func (s *Suite) PrimaryModelID() string {
	return s.Config.PrimaryModelID()
}

func (s *Suite) Start(ctx context.Context) error {
	s.Ctx = ctx

	if err := s.startPostgres(); err != nil {
		return err
	}
	if err := s.createUserPool(); err != nil {
		return err
	}
	if err := s.startCoordinator(); err != nil {
		return err
	}
	if err := s.startProviders(); err != nil {
		return err
	}
	return s.waitForProviderRegistration(3 * time.Minute)
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
				ModelIDs:      modelIDs,
				TrustLevel:    TrustNone,
				AuthTokenPath: authTokenPath,
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

	cmd := execCommandContext(ctx, p.BinaryPath, args...)
	cmd.Stdout = &logWriter{logger: p.Logger, prefix: "provider:stdout"}
	cmd.Stderr = &logWriter{logger: p.Logger, prefix: "provider:stderr"}
	cmd.Env = append(os.Environ(),
		"DARKBLOOM_PID_FILE=/tmp/darkbloom-testbed-"+strconv.Itoa(p.ProviderIndex)+".pid",
		"DARKBLOOM_NO_UPDATE_CHECK=1",
	)
	if cfg.AuthTokenPath != "" {
		cmd.Env = append(cmd.Env, "DARKBLOOM_AUTH_TOKEN_PATH="+cfg.AuthTokenPath)
	}

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start provider: %w", err)
	}

	p.cmd = cmd.Process
	p.Logger.Info("provider started", "binary", p.BinaryPath, "pid", p.cmd.Pid)

	go func() {
		state, _ := cmd.Process.Wait()
		if state != nil && state.ExitCode() >= 0 {
			p.Logger.Warn("provider process exited", "exit_code", state.ExitCode())
		}
	}()

	return nil
}

func (p *Provider) Stop() {
	if p.cancel != nil {
		p.cancel()
	}
	if p.cmd != nil {
		if err := p.cmd.Signal(os.Interrupt); err != nil {
			p.cmd.Kill()
		}
		done := make(chan error, 1)
		go func() {
			_, _ = p.cmd.Wait()
			done <- nil
		}()
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			p.cmd.Kill()
		}
	}
	if p.AuthDir != "" {
		_ = os.RemoveAll(p.AuthDir)
	}
	p.Logger.Info("provider stopped")
}
