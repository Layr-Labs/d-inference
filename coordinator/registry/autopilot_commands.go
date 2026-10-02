package registry

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func (r *Registry) reserveAutopilotAction(c *modelAutopilotController, a autopilotAction, now time.Time) (protocol.ModelAutopilotMessage, bool) {
	// Demand is leaf-locked independently. It may increase after planning, so
	// re-evaluate donor coverage and benefit using a current observation.
	demand := c.demand.ShapeSnapshot(now, c.config.DemandWindow)
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.autopilot != c || !c.config.Enabled || c.config.ObserveOnly || c.paused.Load() {
		return protocol.ModelAutopilotMessage{}, false
	}
	// Exclusive registry lock prevents new admissions and binds all existing
	// p.mu updates before recomputing the donor ledger. Nothing is sent here.
	f := r.autopilotFleetSnapshotLocked(c, demand, now)
	active := f.LegacyPending
	for _, n := range f.Nodes {
		if n.Pending {
			active++
		}
	}
	if active >= c.config.MaxConcurrentOperations {
		return protocol.ModelAutopilotMessage{}, false
	}
	var node *autopilot.Node
	for i := range f.Nodes {
		if f.Nodes[i].ID == a.Node.ID {
			node = &f.Nodes[i]
			break
		}
	}
	if node == nil || f.sessions[node.ID] != a.session || node.Seq != a.Node.Seq || !node.Managed || !node.Idle || node.Pending || !slices.Equal(autopilot.ResidentIDs(node.State), autopilot.ResidentIDs(a.Node.State)) {
		return protocol.ModelAutopilotMessage{}, false
	}
	// Restrict replanning to this recipient, while retaining all other nodes'
	// real coverage. This validates the exact proposed replacement anew.
	for i := range f.Nodes {
		if f.Nodes[i].ID != a.Node.ID {
			f.Nodes[i].Idle = false
		}
	}
	fresh := planAutopilotAction(f, c.config, now)
	if fresh == nil || fresh.Load != a.Load || !slices.Equal(autopilot.SortedStrings(fresh.Unload), autopilot.SortedStrings(a.Unload)) {
		return protocol.ModelAutopilotMessage{}, false
	}
	cmd := protocol.ModelAutopilotMessage{Reason: fresh.Reason, Type: protocol.TypeModelAutopilot, SessionID: node.ID, Revision: node.State.Revision, CommandID: uuid.NewString(), LoadModelID: fresh.Load, UnloadModelIDs: append([]string{}, fresh.Unload...), ExpectedResidentModels: autopilot.ResidentIDs(node.State), ExpiresAtMS: now.Add(c.config.CommandAcceptTimeout).UnixMilli(), LeaseSeconds: int(c.config.MinDwell.Seconds())}
	p := f.sessions[node.ID]
	p.mu.Lock()
	defer p.mu.Unlock()
	// Same-snapshot authority is still required at the exact reservation point.
	if p.capacitySeq != node.Seq || providerAutopilotTransitionLocked(p) || p.pendingCount() != 0 || !providerAutopilotManagedLocked(p) {
		return protocol.ModelAutopilotMessage{}, false
	}
	p.autopilotPending = &autopilotPendingCommand{Command: cmd, SentAt: now, CapacitySeq: p.capacitySeq, Status: "reserved", LastSentAt: now, Attempts: 1, FailureBackoff: c.config.FailureBackoff}
	p.recordDeadlineActivityLocked(now)
	return cmd, true
}

func (r *Registry) sendAutopilotCommand(p *Provider, command protocol.ModelAutopilotMessage) {
	if r.logger != nil {
		r.logger.Info("model autopilot command", "provider_id", p.ID, "command_id", command.CommandID, "load_model", command.LoadModelID, "unload_models", command.UnloadModelIDs)
	}
	var err error
	if r.autopilotSender != nil {
		err = r.autopilotSender(p.ID, command)
	} else {
		var body []byte
		body, err = json.Marshal(command)
		if err == nil {
			// Queue admission is bounded and never waits for a peer socket.
			// Pending ownership lasts through a matching terminal heartbeat;
			// enqueue success is not evidence of delivery or completion.
			err = p.EnqueueText(context.Background(), body)
		}
	}
	if err != nil {
		// A write error is ambiguous: the provider might already have received
		// the command. Never restore donor capacity or issue another command
		// merely because the sender timed out.
		p.mu.Lock()
		if pending := p.autopilotPending; pending != nil && pending.Command.CommandID == command.CommandID {
			if errors.Is(err, ErrProviderWriterQueueFull) && pending.Attempts == 1 && pending.Status == "reserved" && !pending.Uncertain {
				r.queueAutopilotEvent(store.AutopilotRecord{CommandID: command.CommandID, At: time.Now(), ProviderID: p.ID,
					Phase: "failed", Load: command.LoadModelID, Unload: command.UnloadModelIDs,
					Before: command.ExpectedResidentModels, After: command.ExpectedResidentModels})
				p.autopilotBackoffUntil = time.Now().Add(pending.FailureBackoff)
				p.autopilotPending = nil // the writer proved this command was never enqueued
			} else {
				pending.Uncertain = true
			}
		}
		p.mu.Unlock()
		if r.logger != nil {
			r.logger.Warn("model autopilot command write failed", "provider_id", p.ID, "command_id", command.CommandID, "error", err)
		}
	}
}

func (r *Registry) HandleAutopilotStatus(providerID string, session *Provider, msg *protocol.ModelAutopilotStatusMessage) bool {
	if msg == nil || (msg.Status != protocol.LoadModelStatusStarted && msg.Status != protocol.LoadModelStatusSucceeded && msg.Status != protocol.LoadModelStatusFailed) {
		return false
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	p := r.providers[providerID]
	if p == nil || p != session {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.autopilotPending == nil || p.autopilotPending.Command.CommandID != msg.CommandID {
		return false
	}
	if (p.autopilotPending.Status == protocol.LoadModelStatusSucceeded || p.autopilotPending.Status == protocol.LoadModelStatusFailed) && msg.Status != p.autopilotPending.Status {
		return false
	}
	if p.autopilotPending.Status != msg.Status && msg.Status == protocol.LoadModelStatusStarted {
		r.queueAutopilotEvent(store.AutopilotRecord{CommandID: msg.CommandID, At: time.Now(), ProviderID: p.ID, Phase: "started", Load: p.autopilotPending.Command.LoadModelID})
	}
	p.autopilotPending.Status = msg.Status
	return true
}

func (r *Registry) markAutopilotWatchdogs(cfg autopilot.Config, now time.Time) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		p.mu.Lock()
		if pending := p.autopilotPending; pending != nil && now.Sub(pending.SentAt) > cfg.CommandWatchdog {
			if !pending.Uncertain && r.logger != nil {
				r.logger.Warn("model autopilot command watchdog", "provider_id", p.ID, "command_id", pending.Command.CommandID, "age", now.Sub(pending.SentAt))
			}
			if !pending.Uncertain {
				r.queueAutopilotEvent(store.AutopilotRecord{CommandID: pending.Command.CommandID, At: now, ProviderID: p.ID, Phase: "uncertain", Load: pending.Command.LoadModelID})
			}
			pending.Uncertain = true
		}
		p.mu.Unlock()
	}
}
