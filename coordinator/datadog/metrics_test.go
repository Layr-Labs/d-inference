package datadog

import (
	"bytes"
	"errors"
	"log/slog"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/DataDog/datadog-go/v5/statsd"
)

// syncBuffer collects log output from the statsd sender goroutine, which calls
// the error handler off the caller's goroutine.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// statsdCapture is a Client pointed at a real UDP listener with a real statsd
// client behind it. The wire format is the whole contract with the agent — the
// difference between a distribution and a histogram is one byte in a datagram —
// so these tests read the bytes rather than mock the client away.
type statsdCapture struct {
	client *Client
	logs   *syncBuffer
	socket net.PacketConn
	statsd *statsd.Client
}

func newStatsdCapture(t *testing.T) *statsdCapture {
	t.Helper()
	socket, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	// WithoutTelemetry: the client's own internal metrics would otherwise share
	// the socket and every assertion would have to filter them out.
	sd, err := statsd.New(socket.LocalAddr().String(),
		statsd.WithNamespace("d_inference."),
		statsd.WithoutTelemetry())
	if err != nil {
		socket.Close()
		t.Fatal(err)
	}
	logs := &syncBuffer{}
	c := &Client{
		Statsd:     sd,
		logger:     slog.New(slog.NewTextHandler(logs, nil)),
		statsdAddr: socket.LocalAddr().String(),
	}
	t.Cleanup(func() {
		sd.Close()
		socket.Close()
	})
	return &statsdCapture{client: c, logs: logs, socket: socket, statsd: sd}
}

// datagrams flushes the client and returns everything the listener received.
func (s *statsdCapture) datagrams(t *testing.T) string {
	t.Helper()
	if err := s.statsd.Flush(); err != nil {
		t.Fatal(err)
	}
	if err := s.socket.SetReadDeadline(time.Now().Add(500 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 8192)
	var out strings.Builder
	for {
		n, _, err := s.socket.ReadFrom(buf)
		if err != nil {
			var netErr net.Error
			if errors.As(err, &netErr) && netErr.Timeout() {
				break
			}
			t.Fatal(err)
		}
		out.Write(buf[:n])
	}
	return out.String()
}

// TestHistogramSubmitsDistribution is the regression test for the original bug's
// second half: `|h|` makes the agent compute percentiles per flush window and
// submit them as `.95percentile` gauges, which no `pNN:` query can read and no
// wider time range can re-aggregate. Only `|d|` gets raw values to the intake.
func TestHistogramSubmitsDistribution(t *testing.T) {
	cap := newStatsdCapture(t)
	tags := []string{"path:/health", "status_code:200"}
	cap.client.Histogram("http.latency_ms", 12, tags)
	cap.client.Histogram("http.latency_ms", 34, tags)

	got := cap.datagrams(t)
	for _, value := range []string{"12", "34"} {
		want := "d_inference.http.latency_ms:" + value + "|d|#" + strings.Join(tags, ",")
		if !strings.Contains(got, want) {
			t.Fatalf("missing distribution datagram %q in:\n%s", want, got)
		}
	}
	if strings.Contains(got, "|h|") {
		t.Fatalf("histogram type was submitted; the agent would aggregate it locally:\n%s", got)
	}
}

// TestCountAndGaugeWireTypes keeps the other two types from being swept along by
// a change to Histogram: a name already stored as a counter or gauge cannot be
// reinterpreted without breaking every query on it.
func TestCountAndGaugeWireTypes(t *testing.T) {
	cap := newStatsdCapture(t)
	cap.client.Incr("attestation.verified", []string{"trust:hardware"})
	cap.client.Count("inference.requests", 3, nil)
	cap.client.Gauge("fleet.providers", 7, []string{"model:qwen"})

	got := cap.datagrams(t)
	for _, want := range []string{
		"d_inference.attestation.verified:1|c|#trust:hardware",
		"d_inference.inference.requests:3|c",
		"d_inference.fleet.providers:7|g|#model:qwen",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("missing datagram %q in:\n%s", want, got)
		}
	}
}

// TestLockedGaugeStaysAGauge guards the one set of names that cannot change
// type. `provider.mlx_*` shipped on master as gauges, so Datadog has them typed;
// routing them through Histogram would have the intake reject the submission and
// break every existing query on them.
func TestLockedGaugeStaysAGauge(t *testing.T) {
	cap := newStatsdCapture(t)
	tags := []string{"chip_family:M3", "provider_version:0.8.x"}
	cap.client.LockedGauge("provider.mlx_memory.active_gb", 8, tags)

	got := cap.datagrams(t)
	want := "d_inference.provider.mlx_memory.active_gb:8|g|#" + strings.Join(tags, ",")
	if !strings.Contains(got, want) {
		t.Fatalf("missing gauge datagram %q in:\n%s", want, got)
	}
	if strings.Contains(got, "|d|") || strings.Contains(got, "|h|") {
		t.Fatalf("snapshot was submitted as a distribution/histogram:\n%s", got)
	}
}

func TestMetricsNilSafe(t *testing.T) {
	var nilClient *Client
	// A Client with no statsd is the agentless-startup case: NewClient logs and
	// leaves Statsd nil rather than returning an error.
	noStatsd := &Client{}
	for _, c := range []*Client{nilClient, noStatsd} {
		c.Incr("a", nil)
		c.Count("b", 1, nil)
		c.Histogram("c", 1, nil)
		c.Gauge("d", 1, nil)
		c.LockedGauge("e", 1, nil)
		c.statsdError(errors.New("boom"))
	}
	// No logger at all: telemetry must never turn a dropped metric into a panic.
	(&Client{}).statsdError(errors.New("boom"))
}

// TestNoStatsdClientStillReportsDrops covers the second drop mode. If
// statsd.New fails at startup there is no client to raise a delivery error, so
// without this the runbook's one grep string ("DogStatsD delivery failing") could
// never appear while every metric was being discarded.
func TestNoStatsdClientStillReportsDrops(t *testing.T) {
	logs := &syncBuffer{}
	c := &Client{
		logger:     slog.New(slog.NewTextHandler(logs, nil)),
		statsdAddr: "127.0.0.1:8125",
	}

	c.Incr("attestation.verified", nil)
	c.Gauge("fleet.providers", 1, nil)
	c.Histogram("http.latency_ms", 1, nil)

	got := logs.String()
	if !strings.Contains(got, "DogStatsD delivery failing") {
		t.Fatalf("a nil statsd client dropped metrics silently: %q", got)
	}
	// Throttled like any other delivery failure: three calls, one line.
	if lines := strings.Count(got, "\n"); lines != 1 {
		t.Fatalf("expected one throttled line, got %d: %q", lines, got)
	}
	if !strings.Contains(got, "never initialized") {
		t.Fatalf("report does not distinguish the init failure from a dead agent: %q", got)
	}
}

// TestNewClientTagsEveryMetric pins the option set NewClient installs, not the
// one the other tests build by hand: env and service are how every dashboard
// widget and monitor scopes a query, so a metric without them matches nothing.
func TestNewClientTagsEveryMetric(t *testing.T) {
	socket, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer socket.Close()

	c, err := NewClient(Config{
		StatsdAddr: socket.LocalAddr().String(),
		Env:        "production",
		Service:    "d-inference-coordinator",
		FlushSecs:  1,
	}, slog.New(slog.NewTextHandler(&syncBuffer{}, nil)))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	c.Incr("http.requests", []string{"path:/health"})
	if err := c.Statsd.Flush(); err != nil {
		t.Fatal(err)
	}
	if err := socket.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 8192)
	n, _, err := socket.ReadFrom(buf)
	if err != nil {
		t.Fatal(err)
	}
	got := string(buf[:n])
	for _, want := range []string{
		"d_inference.http.requests:1|c",
		"env:production",
		"service:d-inference-coordinator",
		"path:/health",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("missing %q in datagram %q", want, got)
		}
	}
}

// TestCloseIsIdempotent: Close runs on shutdown paths that can be reached twice,
// and the tests in this package hand-assemble Clients with no ticker.
func TestCloseIsIdempotent(t *testing.T) {
	c, err := NewClient(Config{StatsdAddr: "127.0.0.1:18125", FlushSecs: 1}, nil)
	if err != nil {
		t.Fatal(err)
	}
	c.Close()
	c.Close()
	// A hand-built Client has no ticker and no done channel.
	(&Client{}).Close()
}

// TestStatsdErrorRateLimited: a dead agent refuses roughly every other datagram,
// so the report has to be throttled or it buries itself.
func TestStatsdErrorRateLimited(t *testing.T) {
	logs := &syncBuffer{}
	c := &Client{
		logger:     slog.New(slog.NewTextHandler(logs, nil)),
		statsdAddr: "127.0.0.1:8125",
	}

	c.statsdError(errors.New("write udp: connection refused"))
	first := logs.String()
	if !strings.Contains(first, "DogStatsD delivery failing") {
		t.Fatalf("first delivery error was not reported: %q", first)
	}
	if !strings.Contains(first, "127.0.0.1:8125") {
		t.Fatalf("report omits the address an operator needs: %q", first)
	}
	if lines := strings.Count(first, "\n"); lines != 1 {
		t.Fatalf("expected exactly one line, got %d: %q", lines, first)
	}

	for i := 0; i < 500; i++ {
		c.statsdError(errors.New("write udp: connection refused"))
	}
	if lines := strings.Count(logs.String(), "\n"); lines != 1 {
		t.Fatalf("errors inside the report interval were not throttled: %d lines", lines)
	}

	// Once the interval elapses, the next error reports and carries the count of
	// everything swallowed in between — otherwise throttling would hide the
	// scale.
	c.statsdErrMu.Lock()
	c.statsdErrLast = time.Now().Add(-2 * statsdErrReportInterval)
	c.statsdErrMu.Unlock()
	c.statsdError(errors.New("write udp: connection refused"))
	second := logs.String()
	if lines := strings.Count(second, "\n"); lines != 2 {
		t.Fatalf("expected a second report after the interval: %d lines\n%s", lines, second)
	}
	if !strings.Contains(second, "errors_since_last_report=501") {
		t.Fatalf("swallowed errors were not counted: %q", second)
	}
}

// TestNewClientReportsDeadAgent is the end of the original silent failure. A
// connected UDP socket does learn that nothing is listening — the previous
// write's ICMP port-unreachable surfaces as ECONNREFUSED on the next one — but
// the library's default handler is `func(error) {}`, so nobody heard it.
func TestNewClientReportsDeadAgent(t *testing.T) {
	// Bind then release a port so the address is real and (almost certainly)
	// unoccupied, rather than guessing one that something else may hold.
	socket, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := socket.LocalAddr().String()
	socket.Close()

	logs := &syncBuffer{}
	c, err := NewClient(Config{
		StatsdAddr: addr,
		Env:        "test",
		Service:    "test-svc",
		FlushSecs:  1,
	}, slog.New(slog.NewTextHandler(logs, nil)))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if c.Statsd == nil {
		t.Fatal("statsd client should exist: connecting a UDP socket succeeds with no listener")
	}

	// Writes alternate between succeeding and returning the previous write's
	// ECONNREFUSED, so this needs more than one round trip.
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		c.Histogram("http.latency_ms", 1, nil)
		if err := c.Statsd.Flush(); err != nil {
			t.Fatal(err)
		}
		if strings.Contains(logs.String(), "DogStatsD delivery failing") {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("no delivery failure was reported for a dead agent at %s:\n%s", addr, logs.String())
}
