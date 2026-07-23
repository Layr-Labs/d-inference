package promptcontract

import "time"

func applySupervisorDefaults(config *SupervisorConfig) {
	if config.BinaryPath == "" {
		config.BinaryPath = "promptsidecar"
	}
	if config.SocketPath == "" {
		config.SocketPath = DefaultSocketPath
	}
	if config.ArtifactRoot == "" {
		config.ArtifactRoot = DefaultArtifactRoot
	}
	if config.ArtifactBaseURL == "" {
		config.ArtifactBaseURL = "https://models.darkbloom.ai"
	}
	if config.ArtifactTimeout <= 0 {
		config.ArtifactTimeout = defaultDownloadTimeout
	}
	if config.ProvisionWorkers <= 0 {
		config.ProvisionWorkers = defaultProvisionConcurrency
	}
	if config.ProvisionMaxModels <= 0 {
		config.ProvisionMaxModels = defaultProvisionMaxModels
	}
	if config.HeaderReadTimeout <= 0 {
		config.HeaderReadTimeout = DefaultRequestTimeout
	}
	if config.RequestTimeout <= 0 {
		config.RequestTimeout = DefaultRequestTimeout
	}
	if config.HealthTimeout == 0 {
		config.HealthTimeout = DefaultHealthTimeout
	}
	if config.PreloadTimeout == 0 {
		config.PreloadTimeout = DefaultPreloadTimeout
	}
	if config.StartupTimeout == 0 {
		config.StartupTimeout = DefaultPreloadTimeout
	}
	if config.HealthInterval == 0 {
		config.HealthInterval = time.Second
	}
	if config.HealthFailureThreshold == 0 {
		config.HealthFailureThreshold = 5
	}
	if config.ShutdownTimeout <= 0 {
		config.ShutdownTimeout = 2 * time.Second
	}
	if config.RestartBackoffMin <= 0 {
		config.RestartBackoffMin = 100 * time.Millisecond
	}
	if config.RestartBackoffMax < config.RestartBackoffMin {
		config.RestartBackoffMax = 5 * time.Second
	}
	if config.RestartWindow == 0 {
		config.RestartWindow = time.Minute
	}
	if config.RestartMaxInWindow == 0 {
		config.RestartMaxInWindow = 3
	}
	if config.RestartCooldown == 0 {
		config.RestartCooldown = 30 * time.Second
	}
	if config.StderrMaxBytes == 0 {
		config.StderrMaxBytes = 16 << 10
	}
	if config.MaxBodyBytes <= 0 {
		config.MaxBodyBytes = DefaultMaxRequestBytes
	}
	if config.MaxConcurrency <= 0 {
		config.MaxConcurrency = 4
	}
	if config.MaxConnections <= 0 {
		config.MaxConnections = 64
	}
	if config.MaxLoadedContracts <= 0 {
		config.MaxLoadedContracts = 8
	}
	if config.MaxTokens <= 0 {
		config.MaxTokens = DefaultMaxTokens
	}
	if config.MemoryLimitMiB <= 0 {
		config.MemoryLimitMiB = 1024
	}
}
