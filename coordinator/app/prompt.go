package app

import (
	"context"
	"log/slog"
	"net/url"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/config"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

func preparePromptArtifacts(ctx context.Context, cfg config.AppConfig, srv *api.Server, logger *slog.Logger) *promptcontract.Provisioner {
	var promptProvisioner *promptcontract.Provisioner
	if cfg.PromptSidecar.Enabled {
		artifactBaseURL, err := url.Parse(cfg.PromptSidecar.ArtifactBaseURL)
		if err != nil {
			logger.Error("prompt artifact URL rejected", "error", err)
		} else {
			artifactCache, cacheErr := promptcontract.NewArtifactCache(promptcontract.ArtifactCacheConfig{
				Root:            cfg.PromptSidecar.ArtifactRoot,
				BaseURL:         artifactBaseURL,
				DownloadTimeout: cfg.PromptSidecar.ArtifactTimeout,
			})
			if cacheErr != nil {
				logger.Error("prompt artifact cache disabled", "error", cacheErr)
			} else {
				provisioner, provisionErr := promptcontract.NewProvisioner(
					ctx,
					artifactCache,
					promptcontract.ProvisionerConfig{
						MaxConcurrent: cfg.PromptSidecar.ProvisionWorkers,
						MaxModels:     cfg.PromptSidecar.ProvisionMaxModels,
					},
				)
				if provisionErr != nil {
					logger.Error("prompt artifact provisioner disabled", "error", provisionErr)
				} else {
					promptProvisioner = provisioner
					srv.Inference().SetPromptArtifactProvisioner(provisioner)
				}
			}
		}
	}
	return promptProvisioner
}
