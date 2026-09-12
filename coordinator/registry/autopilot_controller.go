package registry

import (
	"context"
	"fmt"
	"slices"
	"time"
)

func (r *Registry) ConfigureAutopilot(cfg AutopilotConfig) error {
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
	r.autopilot = &modelAutopilotController{registry: r, config: cfg}
	return nil
}

func (r *Registry) StartAutopilotController(ctx context.Context, cfg AutopilotConfig) func() {
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
	return cancel
}

func (r *Registry) TriggerAutopilot() AutopilotSummary {
	r.mu.RLock()
	c := r.autopilot
	r.mu.RUnlock()
	if c == nil || !c.config.Enabled {
		return AutopilotSummary{}
	}
	return c.tick(time.Now())
}

func (r *Registry) AutopilotSnapshot() AutopilotSummary {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if r.autopilot == nil {
		return AutopilotSummary{}
	}
	s := r.autopilot.lastSummary
	s.Models = append([]AutopilotModelSummary(nil), s.Models...)
	s.Excluded = map[string]int{}
	for k, v := range r.autopilot.lastSummary.Excluded {
		s.Excluded[k] = v
	}
	return s
}

func (c *modelAutopilotController) tick(now time.Time) AutopilotSummary {
	started := time.Now()
	c.tickMu.Lock()
	defer c.tickMu.Unlock()
	if !c.config.ObserveOnly {
		c.registry.markAutopilotWatchdogs(c.config, now)
		c.registry.retryAutopilotCommands(now)
	}
	f := c.registry.autopilotFleetSnapshot(c, now)
	summary := autopilotSummary(f, c.config, now)
	remaining := c.config.MaxConcurrentOperations - summary.Pending - f.LegacyPending
	limit := min(c.config.MaxActionsPerTick, max(0, remaining))
	for range limit {
		action := planAutopilotAction(f, c.config, now)
		if action == nil {
			break
		}
		summary.Proposed++
		if c.config.ObserveOnly {
			// Hypothetical state stays in this copy. It never reaches routing,
			// pending maps, donor protection of another controller or telemetry of
			// actual capacity. Simulate the debit for this pass only.
			for i := range f.Nodes {
				if f.Nodes[i].ID == action.Node.ID {
					f.Nodes[i].Pending = true
					f.Nodes[i].Future = action.Future
					f.Nodes[i].FutureResidents = []string{}
					for _, m := range action.Node.Residents {
						if !slices.Contains(action.Unload, m) {
							f.Nodes[i].FutureResidents = append(f.Nodes[i].FutureResidents, m)
						}
					}
					if action.Load != "" {
						f.Nodes[i].FutureResidents = append(f.Nodes[i].FutureResidents, action.Load)
					}
				}
			}
			continue
		}
		command, ok := c.registry.reserveAutopilotAction(c, *action, now)
		if !ok { // State moved since the snapshot. Try again on the next bounded tick.
			break
		}
		summary.Issued++
		c.registry.sendAutopilotCommand(action.Node.Session, command)
		f = c.registry.autopilotFleetSnapshot(c, now)
	}
	c.registry.mu.Lock()
	c.lastSummary = summary
	c.registry.mu.Unlock()
	if c.registry.logger != nil {
		c.registry.logger.Info("model autopilot tick", "duration_ms", float64(time.Since(started).Microseconds())/1000, "observe_only", summary.ObserveOnly, "opted_in", summary.OptedIn, "pending", summary.Pending, "uncertain", summary.Uncertain, "proposed", summary.Proposed, "issued", summary.Issued, "excluded", summary.Excluded, "models", summary.Models)
	}
	return summary
}

func autopilotSummary(f autopilotFleet, cfg AutopilotConfig, now time.Time) AutopilotSummary {
	s := AutopilotSummary{At: now, ObserveOnly: cfg.ObserveOnly, Excluded: f.Excluded}
	coverage := autopilotCoverage(f)
	models := make([]string, 0, len(f.Demand)+len(f.Floors))
	for m := range f.Demand {
		models = append(models, m)
	}
	for m := range f.Floors {
		if !slices.Contains(models, m) {
			models = append(models, m)
		}
	}
	slices.Sort(models)
	for _, n := range f.Nodes {
		if n.Managed {
			s.OptedIn++
		}
		if n.Pending {
			s.Pending++
			if n.Uncertain {
				s.Uncertain++
			}
		}
	}
	for _, m := range models {
		eligible := 0
		for _, n := range f.Nodes {
			if n.Managed && n.Idle && !n.Pending && n.Fits[m].MeetsDeadline {
				eligible++
			}
		}
		s.Models = append(s.Models, AutopilotModelSummary{Model: m, LogicalRequests: f.Demand[m].Requests, OfferedRPS: f.Demand[m].Rate, CapacityRPS: coverage.Ready[m], PendingRPS: coverage.Future[m], ProtectedFloor: autopilotFloor(f, m), WarmProviders: coverage.Warm[m], EligibleIdle: eligible, DeficitRPS: max(0, coverage.Need[m]-coverage.Ready[m]-coverage.Future[m])})
	}
	return s
}
