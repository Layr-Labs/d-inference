package service

import (
	"io"
	"log/slog"
	"strings"
	"sync"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// The exchange only needs a provider's existing bound identity; HTTP upgrade,
// authentication, and the real writer remain covered by API integration tests.
func newSessionProvider(endpoint, signingKey string) *registry.Provider {
	return &registry.Provider{
		ID: "p1", PublicKey: endpoint, APNsDeviceToken: "devtok", APNsEnvironment: "production",
		AttestationResult: &attestation.VerificationResult{Valid: true, PublicKey: signingKey},
	}
}

// testShadowStatus is the minimal signed status a protocol-3 provider sends
// with an attestation or assertion.
func testShadowStatus() *protocol.AppAttestStatus {
	return &protocol.AppAttestStatus{OSVersion: "27"}
}

// testAssertionHash is the protocol-3 client hash an assertion for x's
// current challenge signs over status.
func testAssertionHash(x *Session, keyID string, status *protocol.AppAttestStatus) [32]byte {
	return protocol.AppAttestShadowHashV3("assert", x.id, x.s.config.Environment, keyID, x.challenge, x.publicKey, x.accountScope(), status)
}

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// eventLog records emitted exchange events. Exchange workers emit from their
// own goroutines, so every access takes the lock.
type eventLog struct {
	mu     sync.Mutex
	events []map[string]any
}

func (l *eventLog) emit(fields map[string]any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.events = append(l.events, fields)
}

// outcomes lists every event as "stage:outcome".
func (l *eventLog) outcomes() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	var out []string
	for _, e := range l.events {
		out = append(out, e["stage"].(string)+":"+e["outcome"].(string))
	}
	return out
}

// metricLog records metric hook calls; background workers call the hooks from
// their own goroutines, so every access takes the lock.
type metricLog struct {
	mu     sync.Mutex
	incr   []string
	counts map[string][]int64
	gauges map[string][]float64
	hist   map[string]int
}

func newMetricLog() *metricLog {
	return &metricLog{counts: map[string][]int64{}, gauges: map[string][]float64{}, hist: map[string]int{}}
}

func (m *metricLog) metrics() Metrics {
	return Metrics{
		Incr: func(name string, tags []string) {
			m.mu.Lock()
			defer m.mu.Unlock()
			m.incr = append(m.incr, strings.Join(append([]string{name}, tags...), "|"))
		},
		Count: func(name string, v int64, _ []string) {
			m.mu.Lock()
			defer m.mu.Unlock()
			m.counts[name] = append(m.counts[name], v)
		},
		Gauge: func(name string, v float64, _ []string) {
			m.mu.Lock()
			defer m.mu.Unlock()
			m.gauges[name] = append(m.gauges[name], v)
		},
		Histogram: func(name string, _ float64, _ []string) {
			m.mu.Lock()
			defer m.mu.Unlock()
			m.hist[name]++
		},
	}
}

func (m *metricLog) count(name string) []int64 {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]int64(nil), m.counts[name]...)
}

func (m *metricLog) gauge(name string) []float64 {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]float64(nil), m.gauges[name]...)
}

func (m *metricLog) incrCount(entry string) int {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := 0
	for _, e := range m.incr {
		if e == entry {
			n++
		}
	}
	return n
}
