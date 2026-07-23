package promptcontract

import (
	"errors"
	"net/url"
	"path/filepath"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

var ErrInvalidConfig = errors.New("invalid prompt-sidecar configuration")

func ReadSupervisorConfig() SupervisorConfig {
	const prefix = env.EnvPrefix + "_PROMPT_SIDECAR"
	return SupervisorConfig{
		Enabled:                env.EnvBool(prefix+"_ENABLED", false),
		BinaryPath:             env.EnvOr(prefix+"_BINARY", "promptsidecar"),
		SocketPath:             env.EnvOr(prefix+"_SOCKET", DefaultSocketPath),
		ArtifactRoot:           env.EnvOr(prefix+"_ARTIFACT_ROOT", DefaultArtifactRoot),
		ArtifactBaseURL:        env.EnvOr(prefix+"_ARTIFACT_BASE_URL", "https://models.darkbloom.ai"),
		ArtifactTimeout:        time.Duration(env.EnvInt(prefix+"_ARTIFACT_TIMEOUT_MS", 120000)) * time.Millisecond,
		ProvisionWorkers:       env.EnvInt(prefix+"_PROVISION_WORKERS", defaultProvisionConcurrency),
		ProvisionMaxModels:     env.EnvInt(prefix+"_PROVISION_MAX_MODELS", defaultProvisionMaxModels),
		HeaderReadTimeout:      time.Duration(env.EnvInt(prefix+"_HEADER_TIMEOUT_MS", 1000)) * time.Millisecond,
		RequestTimeout:         time.Duration(env.EnvInt(prefix+"_TIMEOUT_MS", 1000)) * time.Millisecond,
		HealthTimeout:          time.Duration(env.EnvInt(prefix+"_HEALTH_TIMEOUT_MS", 250)) * time.Millisecond,
		PreloadTimeout:         time.Duration(env.EnvInt(prefix+"_PRELOAD_TIMEOUT_MS", 120000)) * time.Millisecond,
		StartupTimeout:         time.Duration(env.EnvInt(prefix+"_STARTUP_TIMEOUT_MS", 120000)) * time.Millisecond,
		HealthInterval:         time.Duration(env.EnvInt(prefix+"_HEALTH_INTERVAL_MS", 1000)) * time.Millisecond,
		HealthFailureThreshold: env.EnvInt(prefix+"_HEALTH_FAILURE_THRESHOLD", 5),
		ShutdownTimeout:        time.Duration(env.EnvInt(prefix+"_SHUTDOWN_TIMEOUT_MS", 2000)) * time.Millisecond,
		RestartBackoffMin:      time.Duration(env.EnvInt(prefix+"_RESTART_MIN_MS", 100)) * time.Millisecond,
		RestartBackoffMax:      time.Duration(env.EnvInt(prefix+"_RESTART_MAX_MS", 5000)) * time.Millisecond,
		RestartWindow:          time.Duration(env.EnvInt(prefix+"_RESTART_WINDOW_MS", 60000)) * time.Millisecond,
		RestartMaxInWindow:     env.EnvInt(prefix+"_RESTART_MAX_IN_WINDOW", 3),
		RestartCooldown:        time.Duration(env.EnvInt(prefix+"_RESTART_COOLDOWN_MS", 30000)) * time.Millisecond,
		StderrMaxBytes:         env.EnvInt(prefix+"_STDERR_MAX_BYTES", 16<<10),
		MaxBodyBytes:           env.EnvInt(prefix+"_MAX_BODY_BYTES", DefaultMaxRequestBytes),
		MaxConcurrency:         env.EnvInt(prefix+"_MAX_CONCURRENCY", 4),
		MaxConnections:         env.EnvInt(prefix+"_MAX_CONNECTIONS", 64),
		MaxLoadedContracts:     env.EnvInt(prefix+"_MAX_LOADED_CONTRACTS", 8),
		MaxTokens:              env.EnvInt(prefix+"_MAX_TOKENS", DefaultMaxTokens),
		MemoryLimitMiB:         env.EnvInt(prefix+"_MEMORY_LIMIT_MIB", 1024),
	}
}

func (c SupervisorConfig) Check() error {
	if !c.Enabled {
		return nil
	}
	applySupervisorDefaults(&c)
	artifactURL, artifactURLErr := url.Parse(c.ArtifactBaseURL)
	if c.BinaryPath == "" ||
		!filepath.IsAbs(c.SocketPath) ||
		!filepath.IsAbs(c.ArtifactRoot) ||
		c.SocketPath == c.ArtifactRoot ||
		artifactURLErr != nil ||
		artifactURL.Scheme != "https" ||
		artifactURL.Host == "" ||
		artifactURL.User != nil ||
		artifactURL.RawQuery != "" ||
		artifactURL.Fragment != "" ||
		c.ArtifactTimeout <= 0 ||
		c.ProvisionWorkers <= 0 ||
		c.ProvisionMaxModels <= 0 ||
		c.ProvisionWorkers > c.ProvisionMaxModels ||
		c.HeaderReadTimeout <= 0 ||
		c.RequestTimeout <= 0 ||
		c.HealthTimeout <= 0 ||
		c.PreloadTimeout <= 0 ||
		c.StartupTimeout <= 0 ||
		c.HealthInterval <= 0 ||
		c.HealthFailureThreshold < 2 ||
		c.ShutdownTimeout <= 0 ||
		c.RestartBackoffMin <= 0 ||
		c.RestartBackoffMax < c.RestartBackoffMin ||
		c.RestartWindow <= 0 ||
		c.RestartMaxInWindow <= 0 ||
		c.RestartCooldown <= 0 ||
		c.StderrMaxBytes < 1024 || c.StderrMaxBytes > 1<<20 ||
		c.MaxBodyBytes <= 0 ||
		c.MaxConcurrency <= 0 ||
		c.MaxConnections <= 0 ||
		c.MaxLoadedContracts <= 0 ||
		c.MaxTokens <= 0 ||
		c.MemoryLimitMiB < 256 {
		return ErrInvalidConfig
	}
	return nil
}
