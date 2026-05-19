package registry

import (
	"os"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// Config holds registry-level configuration.
type Config struct {
	MinTrustLevel string // overrides default trust level (empty = use default)
}

// ReadConfig reads registry configuration from environment variables.
func ReadConfig() Config {
	return Config{
		MinTrustLevel: os.Getenv(env.EnvPrefix + "_MIN_TRUST"),
	}
}

func (c Config) Check() error { return nil }
