package api

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Transport samples are local to one provider session and never infer GPU or
// delivery performance from attestation processing time. Failure merely ages
// out the sample; liveness and health keep their existing independent owners.
func (s *Server) providerTransportLoop(ctx context.Context, provider *registry.Provider) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		if ctx.Err() != nil {
			return
		}
		probe, cancel := context.WithTimeout(ctx, 3*time.Second)
		_ = provider.MeasureTransport(probe)
		cancel()
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
