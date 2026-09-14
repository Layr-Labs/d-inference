package main

import (
	"context"
	"log/slog"
	"net/url"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

func configurePromptArtifacts(ctx context.Context, srv *api.Server, cfg promptcontract.SupervisorConfig, logger *slog.Logger) *promptcontract.Provisioner {
	var promptProvisioner *promptcontract.Provisioner
	if cfg.Enabled {
		artifactBaseURL, err := url.Parse(cfg.ArtifactBaseURL)
		if err != nil {
			logger.Error("prompt artifact URL rejected", "error", err)
		} else {
			artifactCache, cacheErr := promptcontract.NewArtifactCache(promptcontract.ArtifactCacheConfig{
				Root:            cfg.ArtifactRoot,
				BaseURL:         artifactBaseURL,
				DownloadTimeout: cfg.ArtifactTimeout,
			})
			if cacheErr != nil {
				logger.Error("prompt artifact cache disabled", "error", cacheErr)
			} else {
				provisioner, provisionErr := promptcontract.NewProvisioner(
					ctx,
					artifactCache,
					promptcontract.ProvisionerConfig{
						MaxConcurrent: cfg.ProvisionWorkers,
						MaxModels:     cfg.ProvisionMaxModels,
					},
				)
				if provisionErr != nil {
					logger.Error("prompt artifact provisioner disabled", "error", provisionErr)
				} else {
					promptProvisioner = provisioner
					srv.SetPromptArtifactProvisioner(provisioner)
				}
			}
		}
	}
	return promptProvisioner
}

func startPromptSidecar(ctx context.Context, srv *api.Server, promptProvisioner *promptcontract.Provisioner, cfg promptcontract.SupervisorConfig, logger *slog.Logger) *promptcontract.Supervisor {
	promptSidecar := promptcontract.NewSupervisor(cfg)
	srv.SetPromptSupervisor(promptSidecar)
	if cfg.Enabled {
		srv.SetPromptContractClient(promptSidecar.Client())
	}
	promptSidecar.Start(ctx)
	if cfg.Enabled && promptProvisioner != nil {
		promptPreloader, err := promptcontract.NewPreloadController(
			promptProvisioner,
			promptSidecar,
			promptcontract.PreloadControllerConfig{},
		)
		if err != nil {
			logger.Error("prompt contract preload gate disabled", "error", err)
		} else {
			srv.SetPromptPreloadController(promptPreloader)
			promptPreloader.Start(ctx)
		}
	}
	return promptSidecar
}
