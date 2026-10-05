package promptcontract

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/preload"
)

type PreloadController struct{ controller *preload.PreloadController }
type PreloadControllerConfig = preload.PreloadControllerConfig
type PreloadControllerStatus = preload.PreloadControllerStatus

// The supervisor retains process ownership; the controller consumes only the
// detached generation/readiness view needed to fence active-set preloading.
type preloadChild struct{ supervisor *Supervisor }

func (c preloadChild) Status() preload.ChildStatus {
	status := c.supervisor.Status()
	return preload.ChildStatus{Running: status.Running, Ready: status.Ready, ChildGeneration: status.ChildGeneration}
}

func NewPreloadController(provisioner *Provisioner, supervisor *Supervisor, config PreloadControllerConfig) (*PreloadController, error) {
	if provisioner == nil || supervisor == nil || supervisor.Client() == nil {
		return nil, ErrInvalidConfig
	}
	controller, err := preload.New(provisioner, preloadChild{supervisor}, supervisor.Client(), config)
	if err != nil {
		return nil, err
	}
	return &PreloadController{controller: controller}, nil
}

func (c *PreloadController) Start(parent context.Context) {
	if c != nil {
		c.controller.Start(parent)
	}
}
func (c *PreloadController) Close() {
	if c != nil {
		c.controller.Close()
	}
}
func (c *PreloadController) Status() PreloadControllerStatus {
	if c == nil {
		return PreloadControllerStatus{}
	}
	return c.controller.Status()
}
func (c *PreloadController) ReadyFor(promptContractID string) bool {
	return c != nil && c.controller.ReadyFor(promptContractID)
}
