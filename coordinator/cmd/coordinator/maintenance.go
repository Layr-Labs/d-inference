package main

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	postgresstore "github.com/eigeninference/d-inference/coordinator/store/postgres"
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
	st, err := postgresstore.NewPostgres(ctx, cfg)
	if err != nil {
		return err
	}
	st.Close()
	slog.Info("coordinator migrations complete", "duration_ms", time.Since(started).Milliseconds())
	return nil
}
