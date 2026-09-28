package registry

import (
	"context"
	"time"
)

const transportFreshness = 90 * time.Second

type transportMeasurement struct {
	rtt       time.Duration
	deviation time.Duration
	at        time.Time
	samples   int
}

// MeasureTransport samples this connection's WebSocket ping/pong round trip.
// RFC control frames use the WebSocket library's control-frame serialization,
// which can interleave with fragmented text frames; no application text bypasses
// the two-lane writer. Waiting for the pong never holds that writer's queue.
// The caller must keep its Read loop running. Do not impose a probe-specific
// write deadline: nhooyr treats expiration during a write as connection failure.
// Its ordinary control-frame failure policy still applies, as for automatic
// pongs. A missing pong keeps this one observer pending until connection teardown;
// an eventual RTT above three seconds is discarded by recordTransportLocked.
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
	if p.Conn == conn && p.Status != StatusOffline && !p.modelIndexDetached {
		p.recordTransportLocked(finished.Sub(start), finished)
	}
	return nil
}

func (p *Provider) recordTransportLocked(rtt time.Duration, now time.Time) {
	if rtt <= 0 || rtt > 3*time.Second {
		return
	}
	m := &p.transport
	if m.at.IsZero() || now.Sub(m.at) > transportFreshness {
		*m = transportMeasurement{rtt: rtt, at: now, samples: 1}
		return
	}
	delta := rtt - m.rtt
	if delta < 0 {
		delta = -delta
	}
	m.deviation = (3*m.deviation + delta) / 4
	m.rtt = (3*m.rtt + rtt) / 4
	m.samples++
	m.at = now
}

func transportForecast(m transportMeasurement, now time.Time) (expected, conservative float64, age int32) {
	if m.samples < 2 || m.at.IsZero() || now.Before(m.at) || now.Sub(m.at) > transportFreshness {
		return 0, 0, -1
	}
	expected = float64(m.rtt) / float64(time.Millisecond)
	conservative = float64(m.rtt+4*m.deviation) / float64(time.Millisecond)
	return expected, max(expected, conservative), heartbeatAgeMs(now, m.at)
}
