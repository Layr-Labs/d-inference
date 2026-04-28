package config

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"strings"
	"time"
)

const (
	BackendMemory   = "memory"
	BackendPostgres = "postgres"
)

type Config struct {
	Addr             string
	Backend          string
	DatabaseURL      string
	AllowOrigin      string
	PseudonymSecret  string
	ActiveNodeWindow time.Duration
}

func Load() (Config, error) {
	cfg := Config{
		Addr:             env("ANALYTICS_ADDR", ":8090"),
		Backend:          strings.ToLower(env("ANALYTICS_BACKEND", BackendMemory)),
		DatabaseURL:      strings.TrimSpace(os.Getenv("ANALYTICS_DATABASE_URL")),
		AllowOrigin:      env("ANALYTICS_ALLOW_ORIGIN", "*"),
		PseudonymSecret:  strings.TrimSpace(os.Getenv("ANALYTICS_PSEUDONYM_SECRET")),
		ActiveNodeWindow: 2 * time.Minute,
	}

	if raw := strings.TrimSpace(os.Getenv("ANALYTICS_ACTIVE_NODE_WINDOW")); raw != "" {
		d, err := time.ParseDuration(raw)
		if err != nil {
			return Config{}, fmt.Errorf("parse ANALYTICS_ACTIVE_NODE_WINDOW: %w", err)
		}
		if d <= 0 {
			return Config{}, fmt.Errorf("ANALYTICS_ACTIVE_NODE_WINDOW must be > 0")
		}
		cfg.ActiveNodeWindow = d
	}

	switch cfg.Backend {
	case BackendMemory:
		if cfg.PseudonymSecret == "" {
			secret, err := randomSecret()
			if err != nil {
				return Config{}, fmt.Errorf("generate pseudonym secret: %w", err)
			}
			cfg.PseudonymSecret = secret
		}
	case BackendPostgres:
		if cfg.DatabaseURL == "" {
			return Config{}, fmt.Errorf("ANALYTICS_DATABASE_URL is required when ANALYTICS_BACKEND=postgres")
		}
		if cfg.PseudonymSecret == "" {
			return Config{}, fmt.Errorf("ANALYTICS_PSEUDONYM_SECRET is required when ANALYTICS_BACKEND=postgres")
		}
	default:
		return Config{}, fmt.Errorf("unsupported ANALYTICS_BACKEND %q", cfg.Backend)
	}

	return cfg, nil
}

func env(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}

func randomSecret() (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}
