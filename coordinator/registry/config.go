package registry

import (
	"fmt"
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

// Check validates the configuration.
// An empty MinTrustLevel is valid and means "use the default".
func (c Config) Check() error {
	if c.MinTrustLevel == "" {
		return nil
	}
	// trustRank returns -1 for unrecognized trust levels.
	if trustRank(TrustLevel(c.MinTrustLevel)) < 0 {
		return fmt.Errorf("registry: invalid MinTrustLevel %q (valid: %q, %q, %q)",
			c.MinTrustLevel, TrustNone, TrustSelfSigned, TrustHardware)
	}
	return nil
}
