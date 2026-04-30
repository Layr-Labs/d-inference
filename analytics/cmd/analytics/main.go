package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/darkbloom/analytics/internal/config"
	"github.com/darkbloom/analytics/internal/httpapi"
	"github.com/darkbloom/analytics/internal/leaderboard"
	"github.com/darkbloom/analytics/internal/pseudonym"
)

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))

	cfg, err := config.Load()
	if err != nil {
		logger.Error("invalid config", "error", err)
		os.Exit(1)
	}

	aliaser, err := pseudonym.NewGenerator(cfg.PseudonymSecret)
	if err != nil {
		logger.Error("failed to initialize pseudonym generator", "error", err)
		os.Exit(1)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	store, err := buildStore(ctx, cfg)
	if err != nil {
		logger.Error("failed to initialize analytics store", "error", err)
		os.Exit(1)
	}
	defer store.Close()

	service := leaderboard.NewService(store, aliaser, time.Now)
	handler := httpapi.NewHandler(logger, service, cfg.AllowOrigin)

	server := &http.Server{
		Addr:              cfg.Addr,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	logger.Info("analytics service starting",
		"addr", cfg.Addr,
		"backend", cfg.Backend,
		"active_node_window", cfg.ActiveNodeWindow.String(),
	)

	go func() {
		sigCh := make(chan os.Signal, 1)
		signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
		sig := <-sigCh

		logger.Info("analytics service shutting down", "signal", sig.String())

		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := server.Shutdown(ctx); err != nil {
			logger.Error("graceful shutdown failed", "error", err)
		}
	}()

	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Error("analytics service failed", "error", err)
		os.Exit(1)
	}
}

func buildStore(ctx context.Context, cfg config.Config) (leaderboard.Store, error) {
	switch cfg.Backend {
	case config.BackendMemory:
		return leaderboard.NewMemoryStore(cfg.ActiveNodeWindow), nil
	case config.BackendPostgres:
		return leaderboard.NewPostgresStore(ctx, cfg.DatabaseURL, cfg.ActiveNodeWindow)
	default:
		return nil, errors.New("unsupported backend")
	}
}
