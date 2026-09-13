package main

import (
	"context"
	"fmt"
	"github.com/eigeninference/d-inference/coordinator/store"
	"log/slog"
	"time"
)

// Runs before app startup: no admin seeding, listeners, workers or MDM clients.
func runMaintenanceCommand(args []string) error {
	if len(args) != 1 || args[0] != "--migrate-only" {
		return fmt.Errorf("usage: coordinator [--migrate-only]")
	}
	cfg := store.ReadConfig()
	if cfg.DatabaseURL == "" {
		return fmt.Errorf("--migrate-only requires EIGENINFERENCE_DATABASE_URL")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	started := time.Now()
	st, err := store.NewPostgres(ctx, cfg)
	if err != nil {
		return err
	}
	st.Close()
	slog.Info("coordinator migrations complete", "duration_ms", time.Since(started).Milliseconds())
	return nil
}
