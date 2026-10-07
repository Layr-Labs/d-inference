package store

import (
	"fmt"
	"os"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// Env var names for store config.
const (
	envDatabaseURL                = env.EnvPrefix + "_DATABASE_URL"
	envAllowMemoryStore           = env.EnvPrefix + "_ALLOW_MEMORY_STORE"
	envMigrationTimeout           = env.EnvPrefix + "_MIGRATION_TIMEOUT"
	envConcurrentIndexLockTimeout = env.EnvPrefix + "_CONCURRENT_INDEX_LOCK_TIMEOUT"

	DefaultMigrationTimeout           = 15 * time.Minute
	DefaultConcurrentIndexLockTimeout = time.Minute
)

// Config holds store backend selection and connection parameters.
type Config struct {
	DatabaseURL      string
	AllowMemoryStore bool
	AdminKey         string // bootstrap admin API key
	// Zero-valued durations in programmatic configs use the defaults.
	MigrationTimeout           time.Duration
	ConcurrentIndexLockTimeout time.Duration
	readError                  error
	// Now supplies the clock for memory-backed account creation. Nil uses time.Now.
	Now func() time.Time `json:"-"`
}

// Check validates invariants: a database URL is required unless the operator
// explicitly opts into the non-durable MemoryStore.
func (c Config) Check() error {
	if c.readError != nil {
		return c.readError
	}
	if c.MigrationTimeout < 0 {
		return fmt.Errorf("%s must be a positive duration", envMigrationTimeout)
	}
	// PostgreSQL lock_timeout is an integer number of milliseconds; do not
	// truncate a positive sub-millisecond duration to zero (unlimited).
	if c.ConcurrentIndexLockTimeout != 0 && (c.ConcurrentIndexLockTimeout < time.Millisecond || c.ConcurrentIndexLockTimeout > 2147483647*time.Millisecond) {
		return fmt.Errorf("%s must be between 1ms and 2147483647ms", envConcurrentIndexLockTimeout)
	}
	if c.DatabaseURL == "" && !c.AllowMemoryStore {
		return fmt.Errorf("%s is required in production; set %s=true for dev-only MemoryStore",
			envDatabaseURL, envAllowMemoryStore)
	}
	return nil
}

// ReadConfig reads store configuration from environment variables.
func ReadConfig() Config {
	c := Config{
		DatabaseURL:                os.Getenv(envDatabaseURL),
		AllowMemoryStore:           os.Getenv(envAllowMemoryStore) == "true",
		AdminKey:                   os.Getenv(env.EnvPrefix + "_ADMIN_KEY"),
		MigrationTimeout:           DefaultMigrationTimeout,
		ConcurrentIndexLockTimeout: DefaultConcurrentIndexLockTimeout,
	}
	for _, setting := range []struct {
		name  string
		value *time.Duration
	}{
		{envMigrationTimeout, &c.MigrationTimeout},
		{envConcurrentIndexLockTimeout, &c.ConcurrentIndexLockTimeout},
	} {
		if raw, set := os.LookupEnv(setting.name); set {
			value, err := time.ParseDuration(raw)
			if err != nil || value <= 0 {
				c.readError = fmt.Errorf("%s must be a positive duration (for example 30m)", setting.name)
				break
			}
			*setting.value = value
		}
	}
	return c
}
