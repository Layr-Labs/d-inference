package inference_test

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/inference"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func init() {
	inference.RegisterTestFactory(func(r *registry.Registry, st store.Store, cfg inference.TestServerConfig, logger *slog.Logger) inference.TestComposition {
		s := api.NewServer(r, st, api.ServerConfig{
			AdminKey: cfg.AdminKey, ServiceReservations: cfg.ServiceReservations,
			FirstContentDeadlineBase: cfg.FirstContentDeadlineBase,
			FirstContentSLAAccounts:  cfg.FirstContentSLAAccounts, MediaFetch: cfg.MediaFetch,
		}, logger)
		return inference.TestComposition{Owner: s.Inference(), Handler: s.Handler, Close: s.Close,
			BindBilling: s.SetBilling, SyncCatalog: s.SyncModelCatalog, SetChallengeInterval: s.SetChallengeInterval}
	})
}
