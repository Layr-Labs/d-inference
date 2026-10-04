package registry

import (
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
)

type warmPoolController struct {
	registry *Registry
	config   warmplan.Config
	state    *warmplan.State
	triggerC chan struct{}
	runtime  *warmplan.Controller[ModelLoadAction]
}
type WarmPoolSnapshot = warmplan.Snapshot[ModelLoadAction]
type WarmPlanningFactory func(warmplan.Dependencies[ModelLoadAction]) *warmplan.Controller[ModelLoadAction]
