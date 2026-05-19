package registry

import "os"

// Config holds registry-level configuration.
type Config struct {
	MinTrustLevel string // overrides default trust level (empty = use default)
}

// ReadConfig reads registry configuration from environment variables.
func ReadConfig() Config {
	return Config{
		MinTrustLevel: os.Getenv("EIGENINFERENCE_MIN_TRUST"),
	}
}

func (c Config) Check() error { return nil }
