package api

import (
	"errors"
	"os"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
	"github.com/eigeninference/d-inference/coordinator/sandboxcontrol"
)

// SandboxServiceConfig separates running the durable control plane from
// admitting new private-alpha work. Keep Enabled true while draining so hosts
// can acknowledge cleanup and owners can retrieve results or delete resources.
// This service does not charge accounts; admission is explicitly allowlisted.
type SandboxServiceConfig struct {
	Enabled                 bool
	AdmissionEnabled        bool
	AllowedAccountIDs       []string
	CommandPayloadRetention time.Duration
}

func (c SandboxServiceConfig) Check() error {
	if c.CommandPayloadRetention < 0 || c.CommandPayloadRetention > sandboxcontrol.MaximumCommandPayloadRetention {
		return errors.New("sandbox command payload retention must be positive and at most 720h")
	}
	if c.AdmissionEnabled && !c.Enabled {
		return errors.New("sandbox admission requires the sandbox service")
	}
	if c.AdmissionEnabled && len(c.AllowedAccountIDs) == 0 {
		return errors.New("sandbox admission requires an account allowlist")
	}
	seen := make(map[string]bool, len(c.AllowedAccountIDs))
	for _, accountID := range c.AllowedAccountIDs {
		if accountID == "" || accountID == "*" || len(accountID) > 256 ||
			strings.ContainsAny(accountID, " \t\r\n,") || seen[accountID] {
			return errors.New("sandbox account allowlist contains an invalid or duplicate account ID")
		}
		seen[accountID] = true
	}
	return nil
}

func (c SandboxServiceConfig) admits(accountID string) bool {
	if !c.Enabled || !c.AdmissionEnabled || accountID == "" {
		return false
	}
	for _, allowed := range c.AllowedAccountIDs {
		if accountID == allowed {
			return true
		}
	}
	return false
}

func readSandboxServiceConfig() SandboxServiceConfig {
	retention := sandboxcontrol.DefaultCommandPayloadRetention
	if raw := strings.TrimSpace(os.Getenv(env.EnvPrefix + "_SANDBOX_COMMAND_PAYLOAD_RETENTION")); raw != "" {
		parsed, err := time.ParseDuration(raw)
		if err != nil || parsed <= 0 {
			retention = -1
		} else {
			retention = parsed
		}
	}
	return SandboxServiceConfig{
		Enabled:                 env.EnvBool(env.EnvPrefix+"_SANDBOX_SERVICE_ENABLED", false),
		AdmissionEnabled:        env.EnvBool(env.EnvPrefix+"_SANDBOX_ADMISSION_ENABLED", false),
		AllowedAccountIDs:       ParseCommaList(os.Getenv(env.EnvPrefix + "_SANDBOX_ALLOWED_ACCOUNT_IDS")),
		CommandPayloadRetention: retention,
	}
}
