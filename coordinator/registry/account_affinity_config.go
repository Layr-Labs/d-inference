package registry

import (
	"fmt"
	"math"
	"os"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/env"
)

const (
	AccountAffinityOff    = "off"
	AccountAffinityShadow = "shadow"
	AccountAffinityOn     = "on"

	defaultAccountAffinityMaxTTFTPenaltyMs = 250.0
	accountAffinityModeEnv                 = env.EnvPrefix + "_ACCOUNT_AFFINITY_MODE"
	accountAffinityMaxTTFTPenaltyEnv       = env.EnvPrefix + "_ACCOUNT_AFFINITY_MAX_TTFT_PENALTY_MS"
)

// AccountAffinityConfig controls a soft account/model placement preference.
// It never widens admission or creates another queue. Zero penalty is an
// explicit no-load-induced-delay setting; the environment default is 250ms.
type AccountAffinityConfig struct {
	Mode string
	// Maximum predicted extra TTFT caused by this machine's load relative to
	// its own idle baseline, not relative to a faster peer.
	MaxTTFTPenaltyMs float64
}

func ReadAccountAffinityConfig() AccountAffinityConfig {
	return AccountAffinityConfig{
		Mode:             normalizedAccountAffinityMode(os.Getenv(accountAffinityModeEnv)),
		MaxTTFTPenaltyMs: envStrictFloat(accountAffinityMaxTTFTPenaltyEnv, defaultAccountAffinityMaxTTFTPenaltyMs),
	}
}

func normalizedAccountAffinityMode(mode string) string {
	mode = strings.ToLower(strings.TrimSpace(mode))
	if mode == "" {
		return AccountAffinityOff
	}
	return mode
}

func (c AccountAffinityConfig) Check() error {
	switch normalizedAccountAffinityMode(c.Mode) {
	case AccountAffinityOff, AccountAffinityShadow, AccountAffinityOn:
	default:
		return fmt.Errorf("account affinity mode must be off, shadow, or on")
	}
	if c.MaxTTFTPenaltyMs < 0 || math.IsNaN(c.MaxTTFTPenaltyMs) || math.IsInf(c.MaxTTFTPenaltyMs, 0) {
		return fmt.Errorf("account affinity max TTFT penalty must be finite and nonnegative")
	}
	return nil
}

// ConfigureAccountAffinity publishes one validated value under the registry
// lock. Reservation commit revalidates this value against its scan snapshot.
// No per-account state, secret, worker, or reconnect cleanup is needed.
func (r *Registry) ConfigureAccountAffinity(cfg AccountAffinityConfig) error {
	if err := cfg.Check(); err != nil {
		return err
	}
	cfg.Mode = normalizedAccountAffinityMode(cfg.Mode)
	r.mu.Lock()
	r.accountAffinity = cfg
	r.mu.Unlock()
	return nil
}
