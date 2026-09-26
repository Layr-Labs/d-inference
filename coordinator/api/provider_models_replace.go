package api

import (
	"context"
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Server) handleModelsReplace(ctx context.Context, provider *registry.Provider, msg *protocol.ModelsReplaceMessage) {
	added, removed, generation, err := s.registry.ReplaceProviderModels(provider, msg)
	ack := protocol.ModelsReplaceAckMessage{
		Type: protocol.TypeModelsReplaceAck, RequestID: msg.RequestID,
		DrainRequestID: msg.DrainRequestID, ValidateOnly: msg.ValidateOnly, Accepted: err == nil,
	}
	if err != nil {
		ack.Error = err.Error()
	}
	data, _ := json.Marshal(ack)
	ackCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if writeErr := provider.WriteTextControl(ackCtx, data); writeErr != nil {
		s.logger.Warn("failed to send models_replace acknowledgement", "provider_id", provider.ID, "error", writeErr)
		return
	}
	if err != nil || msg.ValidateOnly || !s.registry.ResumeProviderModels(provider, generation) {
		return
	}
	provider.Mu().Lock()
	backend, version := provider.Backend, provider.Version
	provider.Mu().Unlock()
	if s.providerSupportsDesiredModels(backend, version) {
		if err := s.registry.RefreshDesiredModels(provider); err != nil {
			s.logger.Warn("failed to refresh desired_models after replacement", "provider_id", provider.ID, "error", err)
		}
	}
	for _, id := range added {
		s.registry.DrainQueuedRequestsForModel(id)
	}
	for _, id := range removed {
		s.registry.DrainQueuedRequestsForModel(id)
		s.registry.RejectUnservableQueuedRequests(id)
	}
}
