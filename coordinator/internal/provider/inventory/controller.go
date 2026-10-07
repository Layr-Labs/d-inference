// Package inventory owns the model replacement acknowledgement protocol and
// the classification of provider model-load outcomes.
package inventory

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
	"log/slog"
)

type Controller struct {
	registry              *registry.Registry
	supportsDesiredModels func(string) bool
	logger                *slog.Logger
}

func New(reg *registry.Registry, supportsDesiredModels func(string) bool, logger *slog.Logger) *Controller {
	return &Controller{registry: reg, supportsDesiredModels: supportsDesiredModels, logger: logger}
}
