package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/config"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type operatorCommand string

const (
	operatorServe         operatorCommand = "serve"
	operatorVersion       operatorCommand = "version"
	operatorConfigCheck   operatorCommand = "config-check"
	operatorRollbackCheck operatorCommand = "rollback-check"
)

func parseOperatorCommand(args []string) (operatorCommand, error) {
	if len(args) == 0 {
		return operatorServe, nil
	}
	if len(args) != 1 {
		return "", errors.New("usage: coordinator [serve|version|check-config|config-check|rollback-check]")
	}
	switch operatorCommand(args[0]) {
	case operatorServe, operatorVersion, operatorConfigCheck, operatorRollbackCheck:
		return operatorCommand(args[0]), nil
	case "check-config":
		return operatorConfigCheck, nil
	default:
		return "", errors.New("usage: coordinator [serve|version|check-config|config-check|rollback-check]")
	}
}

func runOperatorCommand(args []string, logger *slog.Logger) (bool, int) {
	command, err := parseOperatorCommand(args)
	if err != nil {
		logger.Error("invalid coordinator command", "error", err)
		return true, 64
	}
	if command == operatorServe {
		return false, 0
	}

	switch command {
	case operatorVersion:
		return true, writeOperatorJSON(logger, map[string]string{
			"binary":       "go",
			"version":      api.BuildVersion,
			"build_commit": api.BuildCommit,
			"build_date":   api.BuildDate,
		})
	case operatorConfigCheck:
		cfg := config.ReadAppConfig()
		if err := cfg.Check(); err != nil {
			logger.Error("invalid configuration", "error", err)
			return true, 1
		}
		return true, writeOperatorJSON(logger, map[string]any{
			"binary":               "go",
			"configuration_valid":  true,
			"database_configured":  cfg.StoreConfig.DatabaseURL != "",
			"ownership_configured": cfg.StoreConfig.OwnershipEnabled,
		})
	case operatorRollbackCheck:
		if err := checkRollbackSafe(); err != nil {
			logger.Error("Go rollback safety check failed", "error", err)
			return true, 1
		}
		return true, writeOperatorJSON(logger, map[string]any{
			"binary":        "go",
			"rollback_safe": true,
		})
	default:
		panic("unreachable operator command")
	}
}

func checkRollbackSafe() error {
	cfg := config.ReadAppConfig()
	if err := cfg.Check(); err != nil {
		return fmt.Errorf("configuration: %w", err)
	}
	if cfg.StoreConfig.DatabaseURL == "" {
		return errors.New("EIGENINFERENCE_DATABASE_URL is required for rollback-check")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	postgres, err := store.NewPostgres(ctx, cfg.StoreConfig)
	if err != nil {
		return fmt.Errorf("connect to PostgreSQL: %w", err)
	}
	defer postgres.Close()
	if err := postgres.ActivateCoordinatorOwnership(ctx, cfg.StoreConfig.OwnershipEnabled); err != nil {
		return fmt.Errorf("acquire coordinator ownership: %w", err)
	}
	if err := postgres.CheckRollbackSafe(ctx); err != nil {
		return err
	}
	return nil
}

func writeOperatorJSON(logger *slog.Logger, value any) int {
	if err := json.NewEncoder(os.Stdout).Encode(value); err != nil {
		logger.Error("write coordinator command output", "error", err)
		return 1
	}
	return 0
}
