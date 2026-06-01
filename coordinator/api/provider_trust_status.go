package api

import (
	"context"
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

// sendTrustStatus sends the provider its current trust level and status over
// the WebSocket connection. This allows the provider to react — e.g. by
// auto-reporting unified logs when it learns it is self_signed or untrusted.
func (s *Server) sendTrustStatus(provider *registry.Provider, trustLevel registry.TrustLevel, status string, reason string) {
	conn := provider.Conn
	if conn == nil {
		return
	}
	msg := protocol.TrustStatusMessage{
		Type:       protocol.TypeTrustStatus,
		TrustLevel: string(trustLevel),
		Status:     status,
		Reason:     reason,
	}
	data, err := json.Marshal(msg)
	if err != nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = conn.Write(ctx, websocket.MessageText, data)
}
