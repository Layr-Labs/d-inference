package auth

import (
	"fmt"
	"os"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// Config holds Privy authentication configuration.
type Config struct {
	AppID           string // Privy app ID (also used as JWT audience)
	AppSecret       string // Privy app secret (for REST API basic auth)
	VerificationKey string // PEM-encoded ES256 public key from Privy dashboard
}

// ReadConfig reads Privy authentication configuration from environment
// variables. Supports reading the verification key from a file when
// EIGENINFERENCE_PRIVY_VERIFICATION_KEY_FILE is set.
func ReadConfig() Config {
	verificationKey := os.Getenv(env.EnvPrefix + "_PRIVY_VERIFICATION_KEY")
	if keyFile := os.Getenv(env.EnvPrefix + "_PRIVY_VERIFICATION_KEY_FILE"); keyFile != "" {
		if data, err := os.ReadFile(keyFile); err == nil {
			verificationKey = string(data)
		}
	}
	return Config{
		AppID:           os.Getenv(env.EnvPrefix + "_PRIVY_APP_ID"),
		AppSecret:       os.Getenv(env.EnvPrefix + "_PRIVY_APP_SECRET"),
		VerificationKey: verificationKey,
	}
}

// Check validates the auth configuration. Auth is optional.
func (c Config) Check() error {
	if c.AppID == "" {
		return nil
	}
	if c.VerificationKey == "" {
		return fmt.Errorf(env.EnvPrefix + "_PRIVY_VERIFICATION_KEY is required when Privy is configured")
	}
	return nil
}
