package testbed

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"time"

	"github.com/eigeninference/coordinator/internal/api"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
)

type CoordinatorLifecycle struct {
	Server   *api.Server
	Store    store.Store
	Registry *registry.Registry
	Logger   *slog.Logger

	baseURL    string
	httpServer *http.Server
	port       int
	cancel     context.CancelFunc
}

func NewCoordinatorLifecycle(ctx context.Context, st store.Store, logger *slog.Logger, minTrustLevel TrustLevel) (*CoordinatorLifecycle, error) {
	reg := registry.New(logger)
	reg.MinTrustLevel = registry.TrustLevel(minTrustLevel)

	srv := api.NewServer(reg, st, logger)
	srv.SetAdminKey("testbed-admin-key")

	return &CoordinatorLifecycle{
		Server:   srv,
		Store:    st,
		Registry: reg,
		Logger:   logger,
	}, nil
}

func (c *CoordinatorLifecycle) Start(ctx context.Context) error {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return fmt.Errorf("testbed: listen: %w", err)
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
			c.Logger.Error("coordinator http server error", "error", err)
		}
	}()

	c.Registry.StartEvictionLoop(ctx, 90*time.Second)

	c.Logger.Info("test coordinator started", "port", c.port, "base_url", c.baseURL)
	return nil
}

func (c *CoordinatorLifecycle) BaseURL() string {
	return c.baseURL
}

func (c *CoordinatorLifecycle) Port() int {
	return c.port
}

func (c *CoordinatorLifecycle) Stop() error {
	if c.cancel != nil {
		c.cancel()
	}
	if c.httpServer != nil {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := c.httpServer.Shutdown(shutdownCtx); err != nil {
			return fmt.Errorf("testbed: coordinator shutdown: %w", err)
		}
	}
	c.Logger.Info("test coordinator stopped")
	return nil
}

func NewMemoryStore() store.Store {
	return store.NewMemory("testbed-admin-key")
}

func NewPostgresStore(ctx context.Context, databaseURL string) (store.Store, error) {
	pg, err := store.NewPostgres(ctx, databaseURL)
	if err != nil {
		return nil, fmt.Errorf("testbed: connect to postgres: %w", err)
	}
	return pg, nil
}
