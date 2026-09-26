package api

import (
	"context"
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Server) handleModelsReplace(ctx context.Context, provider *registry.Provider, msg *protocol.ModelsReplaceMessage) {
	added, removed, err := s.registry.ReplaceProviderModels(provider, msg)
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
	_ = provider.WriteTextControl(ackCtx, data)
	if err != nil || msg.ValidateOnly {
		return
	}
	for _, id := range added {
		s.registry.DrainQueuedRequestsForModel(id)
	}
	for _, id := range removed {
		s.registry.DrainQueuedRequestsForModel(id)
		s.registry.RejectUnservableQueuedRequests(id)
	}
}
