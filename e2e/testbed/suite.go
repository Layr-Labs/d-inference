package testbed

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
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
	Ctx     context.Context
	Logger  *slog.Logger
	Config  SuiteConfig

	Pg          *deps.PostgresLifecycle
	PgStore     store.Store
	Coordinator *Coordinator
	Providers   []*Provider
	Users       []UserAccount
	Bucket      *deps.BucketClient
	minio       *deps.MinIOLifecycle
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

	cmd    *os.Process
	cancel context.CancelFunc
}

func NewSuite(cfg SuiteConfig) *Suite {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))

	FindRepoRoot()

	if len(cfg.ModelSpecs) == 0 {
		cfg.ModelSpecs = []ModelSpec{{ModelID: resolveModelID(""), NumProviders: 1}}
	}
	for i := range cfg.ModelSpecs {
		cfg.ModelSpecs[i].ModelID = resolveModelID(cfg.ModelSpecs[i].ModelID)
		if cfg.ModelSpecs[i].NumProviders < 0 {
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
	return s.StartWithConfig(ctx, StartConfig{
		Coordinator: true,
		Providers:   true,
	})
}

type StartConfig struct {
	Coordinator bool
	Providers   bool
}

func (s *Suite) StartWithConfig(ctx context.Context, cfg StartConfig) error {
	s.Ctx = ctx

	if s.Config.LocalStack {
		if err := s.startMinIO(); err != nil {
			return err
		}
	}
	if err := s.startPostgres(); err != nil {
		return err
	}
	if err := s.createUserPool(); err != nil {
		return err
	}
	if cfg.Coordinator {
		if err := s.startCoordinatorOnPort(0); err != nil {
			return err
		}
	}
	if cfg.Providers {
		if err := s.startProviders(); err != nil {
			return err
		}
	}
	if s.Coordinator != nil && s.Config.TotalProviders() > 0 {
		return s.waitForProviderRegistration(3 * time.Minute)
	}
	return nil
}

func (s *Suite) StartCoordinator() error {
	return s.startCoordinatorOnPort(0)
}

func (s *Suite) StartCoordinatorOnPort(port int) error {
	return s.startCoordinatorOnPort(port)
}

func (s *Suite) WaitForProviders(timeout time.Duration) error {
	return s.waitForProviderRegistration(timeout)
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
	if s.minio != nil {
		s.minio.Stop()
	}
}

func (s *Suite) startMinIO() error {
	s.minio = deps.NewMinIOLifecycle(s.Logger, 0)
	if err := s.minio.Start(s.Ctx); err != nil {
		return fmt.Errorf("minio: %w", err)
	}

	bc, err := deps.NewBucketClient(s.Ctx, s.minio.EndpointURL, "darkbloom-cdn")
	if err != nil {
		return fmt.Errorf("minio bucket: %w", err)
	}
	s.Bucket = bc

	s.Logger.Info("localstack bucket ready", "cdn_url", s.Bucket.CDNURL())
	return nil
}

func (s *Suite) startPostgres() error {
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

func (s *Suite) startCoordinatorOnPort(port int) error {
	reg := registry.New(s.Logger)
	reg.MinTrustLevel = registry.TrustLevel(TrustNone)

	var catalog []registry.CatalogEntry
	for _, id := range s.Config.AllModelIDs() {
		catalog = append(catalog, registry.CatalogEntry{ID: id})
	}
	reg.SetModelCatalog(catalog)

	srv := api.NewServer(reg, s.PgStore, s.Logger)
	srv.SetAdminKey("testbed-admin-key")
	srv.SetReleaseKey("testbed-release-key")
	srv.SetRuntimeManifest(&api.RuntimeManifest{})
	srv.SetChallengeInterval(1 * time.Hour)
	srv.SetSkipChallenge(true)

	if s.Bucket != nil {
		cdnURL := s.Bucket.CDNURL()
		srv.SetR2CDNURL(cdnURL)
		srv.SetR2SitePackagesCDNURL(cdnURL)
	}

	ledger := payments.NewLedger(s.PgStore)
	billingSvc := billing.NewService(s.PgStore, ledger, s.Logger, billing.Config{MockMode: true})
	srv.SetBilling(billingSvc)

	reg.SetQueue(registry.NewRequestQueue(s.Config.QueueCapacity, s.Config.QueueTimeout))

	s.Coordinator = &Coordinator{
		Server:   srv,
		Registry: reg,
	}

	return s.Coordinator.StartOnPort(s.Ctx, s.Logger, port)
}

func (s *Suite) startProviders() error {
	if s.Config.TotalProviders() == 0 {
		s.Logger.Info("no providers configured, skipping provider startup")
		return nil
	}

	binaryPath, err := BuildProvider(s.Ctx, s.Logger)
	if err != nil {
		return fmt.Errorf("build provider: %w", err)
	}

	providerIdx := 0
	for _, spec := range s.Config.ModelSpecs {
		for j := 0; j < spec.NumProviders; j++ {
			if providerIdx > 0 {
				time.Sleep(500 * time.Millisecond)
			}
			p := &Provider{
				BinaryPath:    binaryPath,
				Logger:        s.Logger.With("provider_index", providerIdx, "model", spec.ModelID),
				ProviderIndex: providerIdx,
			}
			if err := p.Start(s.Ctx, s.Coordinator.BaseURL(), ProviderConfig{
				ModelID:    spec.ModelID,
				TrustLevel: TrustNone,
			}); err != nil {
				return fmt.Errorf("start provider %d (%s): %w", providerIdx, spec.ModelID, err)
			}
			s.Providers = append(s.Providers, p)
			providerIdx++
		}
	}
	return nil
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

	for _, id := range s.Coordinator.Registry.ProviderIDs() {
		s.Coordinator.Registry.ForceTrustProvider(id)
	}
	s.Logger.Info("providers force-trusted for testing")
	return nil
}

func (c *Coordinator) Start(ctx context.Context, logger *slog.Logger) error {
	return c.startOnPort(ctx, logger, 0)
}

func (c *Coordinator) StartOnPort(ctx context.Context, logger *slog.Logger, port int) error {
	return c.startOnPort(ctx, logger, port)
}

func (c *Coordinator) startOnPort(ctx context.Context, logger *slog.Logger, port int) error {
	var listener *tcpListener
	var err error
	if port > 0 {
		l, e := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if e != nil {
			return fmt.Errorf("listen on port %d: %w", port, e)
		}
		p := l.Addr().(*net.TCPAddr).Port
		listener = &tcpListener{inner: l, port: p, baseURL: "http://127.0.0.1:" + strconv.Itoa(p)}
	} else {
		listener, err = netListen()
		if err != nil {
			return fmt.Errorf("listen: %w", err)
		}
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
	if cfg.ModelID != "" {
		args = append(args, "--model", cfg.ModelID)
	}

	cmd := execCommandContext(ctx, p.BinaryPath, args...)
	cmd.Stdout = &logWriter{logger: p.Logger, prefix: "provider:stdout"}
	cmd.Stderr = &logWriter{logger: p.Logger, prefix: "provider:stderr"}
	cmd.Env = append(os.Environ(),
		"DARKBLOOM_PID_FILE=/tmp/darkbloom-testbed-"+strconv.Itoa(p.ProviderIndex)+".pid",
	)

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
	p.Logger.Info("provider stopped")
}
