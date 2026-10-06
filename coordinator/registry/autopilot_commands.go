package registry

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/eigeninference/d-inference/coordinator/store"
)

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
		p.autopilotState.WriteFailed(p.ID, command, errors.Is(err, ErrProviderWriterQueueFull), time.Now, r.queueAutopilotEvent)
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
	return p.autopilotState.Status(p.ID, msg, time.Now, r.queueAutopilotEvent)
}

func (r *Registry) markAutopilotWatchdogs(cfg autopilot.Config, now time.Time) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		p.mu.Lock()
		p.autopilotState.Watchdog(p.ID, cfg.CommandWatchdog, now, func(record store.AutopilotRecord, age time.Duration) {
			if r.logger != nil {
				r.logger.Warn("model autopilot command watchdog", "provider_id", p.ID, "command_id", record.CommandID, "age", age)
			}
			r.queueAutopilotEvent(record)
		})
		p.mu.Unlock()
	}
}

func (r *Registry) prepareAutopilotDelivery(action autopilotAction, command protocol.ModelAutopilotMessage, now time.Time) bool {
	p := action.Session
	p.mu.Lock()
	delivery, ok := p.autopilotState.PrepareDelivery()
	p.mu.Unlock()
	if !ok {
		return false
	}
	if !r.recordAutopilotReservation(action, delivery) {
		p.mu.Lock()
		p.autopilotState.RollbackDelivery(delivery)
		p.mu.Unlock()
		r.queueAutopilotEvent(store.AutopilotRecord{CommandID: command.CommandID, At: now, ProviderID: action.Node.ID, Phase: "failed", Load: action.Load})
		return false
	}
	return true
}
