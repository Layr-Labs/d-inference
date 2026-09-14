package profiler

import (
	"strings"

	"github.com/eigeninference/d-inference/coordinator/env"
)

const (
	EnvEnabled        = env.EnvPrefix + "_PROFILER"
	EnvSampleRate     = env.EnvPrefix + "_PROFILE_SAMPLE_RATE"
	DefaultSampleRate = 0.1
)

// Config controls the heavy request profiler. Compact accounting evidence is
// owned by the request lifecycle and is independent of this configuration.
type Config struct {
	Enabled    bool
	SampleRate float64
}

// ConfigFromEnv preserves the on-by-default kill switch and the existing
// floating-point parser. Only the case-insensitive word "off" disables it.
func ConfigFromEnv() Config {
	return normalizeConfig(Config{
		Enabled:    !strings.EqualFold(strings.TrimSpace(env.EnvOr(EnvEnabled, "on")), "off"),
		SampleRate: env.EnvFloat(EnvSampleRate, DefaultSampleRate),
	})
}

func normalizeConfig(config Config) Config {
	if config.SampleRate < 0 {
		config.SampleRate = 0
	}
	if config.SampleRate > 1 {
		config.SampleRate = 1
	}
	return config
}
