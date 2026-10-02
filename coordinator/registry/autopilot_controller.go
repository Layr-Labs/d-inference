package registry

import (
	"context"
	"fmt"
	"slices"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/eigeninference/d-inference/coordinator/store"
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
	r.autopilot = &modelAutopilotController{registry: r, config: cfg}
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
		c.paused.Store(true)
		c.tickMu.Lock()
		c.refreshControlLeases(time.Now())
		c.registry.flushAutopilotEvents()
		c.tickMu.Unlock()
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
	started := time.Now()
	c.tickMu.Lock()
	defer c.tickMu.Unlock()
	ledgerReady := c.registry.flushAutopilotEvents()
	c.refreshControlLeases(time.Now())
	if !c.config.ObserveOnly {
		c.registry.markAutopilotWatchdogs(c.config, now)
		c.registry.retryAutopilotCommands(now)
	}
	f := c.registry.autopilotFleetSnapshot(c, now)
	summary := autopilotSummary(f, c.config, now)
	remaining := c.config.MaxConcurrentOperations - summary.Pending - f.LegacyPending
	limit := min(c.config.MaxActionsPerTick, max(0, remaining))
	if c.paused.Load() || !ledgerReady {
		limit = 0
	}
	for range limit {
		action := planAutopilotAction(f, c.config, now)
		if action == nil {
			break
		}
		summary.Proposed++
		if c.config.ObserveOnly {
			c.registry.queueAutopilotEvent(store.AutopilotRecord{Reason: action.Reason, Shape: autopilot.ShapeLabel(action.Workload), CommandID: autopilotProposalID(*action), At: now, ProviderID: action.Node.ID, Phase: "proposed", Load: action.Load, Unload: action.Unload, Before: autopilot.ResidentIDs(action.Node.State), Benefit: action.Benefit})
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
		action.session.mu.Lock()
		pending := action.session.autopilotPending
		action.session.mu.Unlock()
		if pending == nil {
			break
		}
		if !c.registry.recordAutopilotReservation(*action, pending) {
			action.session.mu.Lock()
			if action.session.autopilotPending == pending {
				action.session.autopilotPending = nil
			}
			action.session.mu.Unlock()
			c.registry.queueAutopilotEvent(store.AutopilotRecord{CommandID: command.CommandID, At: now, ProviderID: action.Node.ID, Phase: "failed", Load: action.Load})
			break
		}
		summary.Issued++
		c.registry.sendAutopilotCommand(action.session, command)
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
