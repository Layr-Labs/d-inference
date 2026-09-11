package testbed

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/e2e/testbed/deps"
)

type Coordinator struct {
	Server   *api.Server
	Registry *registry.Registry
	baseURL  string
	port     int

	httpServer *http.Server
	cancel     context.CancelFunc
}

func (s *Suite) startStore() error {
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

	if len(s.Config.CatalogModels) == 0 {
		var catalog []registry.CatalogEntry
		for _, id := range s.Config.AllModelIDs() {
			catalog = append(catalog, registry.CatalogEntry{ID: id})
		}
		reg.SetModelCatalog(catalog)
	} else if err := seedCatalog(s.PgStore, s.Config.CatalogModels, s.Config.ModelAliases); err != nil {
		return err
	}

	srv := api.NewServer(reg, s.PgStore, api.ServerConfig{
		FirstContentDeadlineBase: s.Config.FirstContentDeadlineBase,
	}, s.Logger)
	if len(s.Config.CatalogModels) > 0 {
		srv.SyncModelCatalog()
	}
	srv.SetAdminKey("testbed-admin-key")
	srv.SetRuntimeManifest(&api.RuntimeManifest{})
	srv.SetChallengeInterval(1 * time.Hour)
	srv.SetSkipChallenge(true)
	srv.SetAllowDuplicateProviderSerialsForTesting(s.Config.ProviderTargets == nil)

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

func (c *Coordinator) Start(ctx context.Context, logger *slog.Logger) error {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return fmt.Errorf("listen: %w", err)
	}
	c.port = listener.Addr().(*net.TCPAddr).Port
	c.baseURL = "http://127.0.0.1:" + strconv.Itoa(c.port)

	ctx, c.cancel = context.WithCancel(ctx)

	c.httpServer = &http.Server{
		Handler:      c.Server.Handler(),
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 0,
		IdleTimeout:  120 * time.Second,
	}

	go func() {
		if err := c.httpServer.Serve(listener); err != nil && err != http.ErrServerClosed {
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

func NewMemoryStore() store.Store {
	return store.NewMemory(store.Config{AdminKey: "testbed-admin-key"})
}

func NewPostgresStore(ctx context.Context, databaseURL string) (store.Store, error) {
	pg, err := store.NewPostgres(ctx, store.Config{DatabaseURL: databaseURL})
	if err != nil {
		return nil, fmt.Errorf("connect to postgres: %w", err)
	}
	return pg, nil
}
