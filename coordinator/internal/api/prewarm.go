package api

import (
	"context"
	"encoding/json"
	"time"

	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/registry"
	"nhooyr.io/websocket"
)

const (
	standbyPrewarmTimeout  = 2 * time.Second
	maxStandbyPrewarmHints = 2
)

func providerIsReadyForModel(p *registry.Provider, model string) bool {
	if p == nil || model == "" {
		return false
	}
	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.CurrentModel == model {
		return true
	}
	for _, warm := range p.WarmModels {
		if warm == model {
			return true
		}
	}
	return false
}

func (s *Server) dispatchStandbyPreloads(ctx context.Context, model string, primary *registry.Provider) {
	if s == nil || s.registry == nil || model == "" {
		return
	}
	writer := s.providerPrewarmWriter
	if writer == nil {
		writer = s.writeProviderPrewarm
	}
	primaryID := ""
	if primary != nil {
		primaryID = primary.ID
	}
	count := 0
	s.registry.ForEachProvider(func(p *registry.Provider) {
		if count >= maxStandbyPrewarmHints || p == nil || p.ID == primaryID {
			return
		}
		p.Mu().Lock()
		eligible := p.Backend == registry.BackendMLXSwift &&
			p.Status != registry.StatusOffline && p.Status != registry.StatusUntrusted &&
			p.RuntimeVerified && providerHasModelLocked(p, model)
		p.Mu().Unlock()
		if !eligible || providerIsReadyForModel(p, model) {
			return
		}
		count++
		go func(provider *registry.Provider) {
			prewarmCtx, cancel := context.WithTimeout(ctx, standbyPrewarmTimeout)
			defer cancel()
			msg := protocol.LoadModelMessage{Type: protocol.TypeLoadModel, ModelID: model}
			if err := writer(prewarmCtx, provider, msg); err != nil && s.logger != nil {
				s.logger.Debug("failed to dispatch standby preload", "provider_id", provider.ID, "model", model, "error", err)
			}
		}(p)
	})
}

func providerHasModelLocked(p *registry.Provider, model string) bool {
	for _, m := range p.Models {
		if m.ID == model {
			return true
		}
	}
	return false
}

func (s *Server) writeProviderPrewarm(ctx context.Context, p *registry.Provider, msg protocol.LoadModelMessage) error {
	if p == nil || p.Conn == nil {
		return nil
	}
	data, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	return p.Conn.Write(ctx, websocket.MessageText, data)
}
