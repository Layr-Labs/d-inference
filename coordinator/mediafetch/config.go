package mediafetch

import "github.com/eigeninference/d-inference/coordinator/internal/mediafetch/policy"

// Config controls the resolver's outbound fetch and resource limits.
type Config = policy.Config

// Error carries the public failure response and private diagnostic separately.
type Error = policy.Error

const (
	DefaultMaxFileBytes       = policy.DefaultMaxFileBytes
	DefaultMaxTotalBytes      = policy.DefaultMaxTotalBytes
	DefaultMaxInlinedBytes    = policy.DefaultMaxInlinedBytes
	DefaultMaxParts           = policy.DefaultMaxParts
	DefaultTimeout            = policy.DefaultTimeout
	DefaultTotalDeadline      = policy.DefaultTotalDeadline
	DefaultConcurrency        = policy.DefaultConcurrency
	DefaultGlobalConcurrency  = policy.DefaultGlobalConcurrency
	DefaultMaxImageMegapixels = policy.DefaultMaxImageMegapixels
)

// DefaultConfig returns the production resolver limits.
func DefaultConfig() Config { return policy.DefaultConfig() }

// ConfigFromEnv reads operator configuration without hiding invalid values.
func ConfigFromEnv() Config { return policy.ConfigFromEnv() }
