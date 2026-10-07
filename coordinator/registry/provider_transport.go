package registry

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/transport"
)

// MeasureTransport samples this connection's WebSocket ping/pong round trip.
// RFC control frames use the WebSocket library's control-frame serialization,
// which can interleave with fragmented text frames; no application text bypasses
// the two-lane writer. Waiting for the pong never holds that writer's queue.
// The caller must keep its Read loop running. Do not impose a probe-specific
// write deadline: nhooyr treats expiration during a write as connection failure.
// Its ordinary control-frame failure policy still applies, as for automatic
// pongs. A missing pong keeps this one observer pending until connection teardown;
// an eventual RTT above three seconds is discarded by the measurement history.
func (p *Provider) MeasureTransport() error {
	p.mu.Lock()
	conn := p.Conn
	p.mu.Unlock()
	if conn == nil {
		return errProviderWriterStopped
	}
	start := time.Now()
	if err := conn.Ping(context.Background()); err != nil {
		return err
	}
	finished := time.Now()
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.Conn == conn && p.Status != StatusOffline && (p.modelMembership == nil || p.modelMembership.Active()) {
		if p.transport == nil {
			p.transport = &transport.History{}
		}
		p.transport.Record(finished.Sub(start), finished)
	}
	return nil
}

func (r *Registry) newTransportHistory(id string) *transport.History {
	if r.transportFactory != nil {
		if history := r.transportFactory(id); history != nil {
			return history
		}
	}
	return &transport.History{}
}
