// Package transport retains accepted connection round-trip measurements.
package transport

import "time"

const Freshness = 90 * time.Second

// History is serialized by the owning provider's mutex, including disconnect
// reset and forecast reads. Its zero value has no qualified measurement.
type History struct {
	rtt       time.Duration
	deviation time.Duration
	at        time.Time
	samples   int
}

func (m *History) Record(rtt time.Duration, now time.Time) {
	if rtt <= 0 || rtt > 3*time.Second {
		return
	}
	if m.at.IsZero() || now.Sub(m.at) > Freshness {
		*m = History{rtt: rtt, at: now, samples: 1}
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

func (m *History) SampleCount() int {
	if m == nil {
		return 0
	}
	return m.samples
}

func (m *History) Forecast(now time.Time) (expected, conservative float64, age int32) {
	if m.SampleCount() < 2 || m.at.IsZero() || now.Before(m.at) || now.Sub(m.at) > Freshness {
		return 0, 0, -1
	}
	expected = float64(m.rtt) / float64(time.Millisecond)
	conservative = float64(m.rtt+4*m.deviation) / float64(time.Millisecond)
	// Qualified observations are at most 90 seconds old, well within int32.
	return expected, max(expected, conservative), int32(now.Sub(m.at).Milliseconds())
}

func (m *History) Reset() {
	if m != nil {
		*m = History{}
	}
}
