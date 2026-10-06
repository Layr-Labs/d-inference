package provider

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Transport samples are local to one provider session and never infer GPU or
// delivery performance from attestation processing time. Only one probe can be
// outstanding: an unanswered pong waits for ordinary connection teardown rather
// than introducing a separate measurement deadline that could close the socket.
func (s *Owner) providerTransportLoop(ctx context.Context, provider *registry.Provider) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		if ctx.Err() != nil {
			return
		}
		_ = provider.MeasureTransport()
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
