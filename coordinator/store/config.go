package store

import (
	"fmt"
	"os"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// Env var names for store config.
const (
	envDatabaseURL      = env.EnvPrefix + "_DATABASE_URL"
	envAllowMemoryStore = env.EnvPrefix + "_ALLOW_MEMORY_STORE"
	envOwnershipEnabled = env.EnvPrefix + "_COORDINATOR_OWNERSHIP_ENABLED"
)

// Config holds store backend selection and connection parameters.
type Config struct {
	DatabaseURL      string
	AllowMemoryStore bool
	OwnershipEnabled bool
	AdminKey         string // bootstrap admin API key
}

// Check validates invariants: a database URL is required unless the operator
// explicitly opts into the non-durable MemoryStore.
func (c Config) Check() error {
	if c.DatabaseURL == "" && !c.AllowMemoryStore {
		return fmt.Errorf("%s is required in production; set %s=true for dev-only MemoryStore",
			envDatabaseURL, envAllowMemoryStore)
	}
	return nil
}

// ReadConfig reads store configuration from environment variables.
func ReadConfig() Config {
	return Config{
		DatabaseURL:      os.Getenv(envDatabaseURL),
		AllowMemoryStore: os.Getenv(envAllowMemoryStore) == "true",
		OwnershipEnabled: os.Getenv(envOwnershipEnabled) == "true",
		AdminKey:         os.Getenv(env.EnvPrefix + "_ADMIN_KEY"),
	}
}
