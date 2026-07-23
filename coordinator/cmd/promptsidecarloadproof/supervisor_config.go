package main

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

func proofSupervisorConfig(
	args arguments,
	socketPath string,
	maxLoadedContracts, maxConcurrency int,
) promptcontract.SupervisorConfig {
	return promptcontract.SupervisorConfig{
		Enabled:                true,
		BinaryPath:             args.BinaryPath,
		SocketPath:             socketPath,
		ArtifactRoot:           args.ArtifactRoot,
		ArtifactBaseURL:        "https://models.darkbloom.ai",
		ArtifactTimeout:        2 * time.Minute,
		ProvisionWorkers:       1,
		ProvisionMaxModels:     productionModelCount,
		HeaderReadTimeout:      time.Second,
		RequestTimeout:         time.Second,
		HealthTimeout:          250 * time.Millisecond,
		PreloadTimeout:         2 * time.Minute,
		StartupTimeout:         2 * time.Minute,
		HealthInterval:         100 * time.Millisecond,
		HealthFailureThreshold: 5,
		ShutdownTimeout:        2 * time.Second,
		RestartBackoffMin:      100 * time.Millisecond,
		RestartBackoffMax:      5 * time.Second,
		RestartWindow:          time.Minute,
		RestartMaxInWindow:     3,
		RestartCooldown:        30 * time.Second,
		StderrMaxBytes:         16 << 10,
		MaxBodyBytes:           promptcontract.DefaultMaxRequestBytes,
		MaxConcurrency:         maxConcurrency,
		MaxConnections:         64,
		MaxLoadedContracts:     maxLoadedContracts,
		MaxTokens:              promptcontract.DefaultMaxTokens,
		MemoryLimitMiB:         args.MaxRSSMiB,
	}
}
