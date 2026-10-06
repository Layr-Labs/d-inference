package registry

import (
	"context"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func (r *Registry) ConfigureAutopilot(cfg autopilot.Config) error {
	if err := cfg.Check(); err != nil {
		return err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	// Startup-only, like routing policy configuration. A running controller is
	// never replaced underneath in-flight command ownership.
	if r.autopilot != nil {
		if r.autopilot.config != cfg {
			return fmt.Errorf("autopilot is already configured; restart to change rollout settings")
		}
		return nil
	}
	demand := r.autopilotDemand
	if demand == nil {
		demand = &autopilot.DemandTracker{}
	}
	c := &modelAutopilotController{registry: r, config: cfg, demand: demand}
	c.control = r.newAutopilotControl(c)
	r.autopilot = c
	return nil
}

func (r *Registry) StartAutopilotController(ctx context.Context, cfg autopilot.Config) func() {
	if err := r.ConfigureAutopilot(cfg); err != nil {
		r.logger.Error("invalid autopilot configuration", "error", err)
		return func() {}
	}
	if !cfg.Enabled {
		return func() {}
	}
	r.mu.Lock()
	c := r.autopilot
	if c.running {
		r.mu.Unlock()
		return func() {}
	}
	c.running = true
	r.mu.Unlock()
	ctx, cancel := context.WithCancel(ctx)
	go func() {
		defer func() { r.mu.Lock(); c.running = false; r.mu.Unlock() }()
		ticker := time.NewTicker(cfg.Interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case now := <-ticker.C:
				c.tick(now)
			}
		}
	}()
	return func() {
		c.control.Stop()
		cancel()
	}
}

func (r *Registry) TriggerAutopilot() autopilot.Summary {
	r.mu.RLock()
	c := r.autopilot
	r.mu.RUnlock()
	if c == nil || !c.config.Enabled {
		return autopilot.Summary{}
	}
	return c.tick(time.Now())
}

func (r *Registry) AutopilotSnapshot() autopilot.Summary {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if r.autopilot == nil {
		return autopilot.Summary{}
	}
	s := r.autopilot.lastSummary
	s.Paused = r.autopilot.paused.Load()
	s.Enabled = r.autopilot.config.Enabled
	s.ObserveOnly = r.autopilot.config.ObserveOnly
	s.Running = r.autopilot.running
	s.Models = append([]autopilot.ModelSummary(nil), s.Models...)
	s.Excluded = map[string]int{}
	for k, v := range r.autopilot.lastSummary.Excluded {
		s.Excluded[k] = v
	}
	return s
}

func (c *modelAutopilotController) tick(now time.Time) autopilot.Summary {
	return c.control.Tick(now)
}
