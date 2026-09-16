package metrics

import "fmt"

// The declare* helpers below are the only way a declaration comes into
// existence, and every one of them takes the tag keys as the last argument so a
// metric's dimensions are read off the same line as its name.

// counter declares a counter. See Counter for what a sample means on this
// transport (a delta, not a total).
func (m *Metrics) counter(name, help string, labelKeys ...string) *Counter {
	return &Counter{declaration: m.declare(name, help, KindCount, labelKeys)}
}

// mirroredCounter declares a counter that is also mirrored into the in-process
// registry under a second name. The two names differ historically; declaring
// them together is the only way that pairing stays visible.
func (m *Metrics) mirroredCounter(name, mirror, help string, labelKeys ...string) *Counter {
	d := m.declare(name, help, KindCount, labelKeys)
	d.mirror = mirror
	return &Counter{declaration: d}
}

// gauge declares a gauge. Remember that a pushed gauge is not remembered by
// anything downstream: whatever sets it has to keep setting it.
func (m *Metrics) gauge(name, help string, labelKeys ...string) *Gauge {
	return &Gauge{declaration: m.declare(name, help, KindGauge, labelKeys)}
}

// lockedGauge declares a gauge for a name Datadog already stores as a gauge,
// where a distribution would be the better model. It is a compatibility marker,
// not a preference: the intake rejects a submission that changes a stored name's
// type, and every saved query on the name breaks with it. Nothing new should be
// declared this way — a fleet-wide reading tagged only by coarse dimensions is
// aggregated client-side to one arbitrary reporter's value per flush window, so
// new snapshots go to distribution.
func (m *Metrics) lockedGauge(name, help string, labelKeys ...string) *Gauge {
	d := m.declare(name, help, KindGauge, labelKeys)
	d.locked = true
	return &Gauge{declaration: d}
}

// distribution declares a distribution: raw values forwarded so Datadog
// aggregates over the queried range.
func (m *Metrics) distribution(name, help string, labelKeys ...string) *Distribution {
	return &Distribution{declaration: m.declare(name, help, KindDistribution, labelKeys)}
}

// mirroredDistribution declares a distribution that is also observed into the
// in-process registry's histogram of the same reading.
func (m *Metrics) mirroredDistribution(name, mirror, help string, labelKeys ...string) *Distribution {
	d := m.declare(name, help, KindDistribution, labelKeys)
	d.mirror = mirror
	return &Distribution{declaration: d}
}

func (m *Metrics) declare(name, help string, kind Kind, labelKeys []string) *declaration {
	if _, exists := m.byName[name]; exists {
		panic(fmt.Sprintf("metrics: %q is declared twice; two declarations of one name are two views of one series", name))
	}
	d := &declaration{
		name:      name,
		help:      help,
		labelKeys: labelKeys,
		kind:      kind,
		sinks:     m.sinks,
	}
	m.byName[name] = d
	m.declared = append(m.declared, d)
	return d
}
