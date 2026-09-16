package metrics

import (
	"errors"
	"io"
	"log/slog"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/datadog"
)

// The wire format is the whole contract with the agent: a Kind is a single byte
// in a datagram, and the difference between `|d|` and `|h|` decides whether
// Datadog stores raw values or per-flush-window percentile gauges nothing can
// re-aggregate. So these tests put a real UDP listener behind a real
// datadog.Client and read the bytes, rather than asserting against the Sink
// interface — the interface is exactly the layer that could be right while the
// wire is wrong.

type wireCapture struct {
	metrics *Metrics
	client  *datadog.Client
	socket  net.PacketConn
}

// newWireCapture builds a catalog with no declarations over a live DogStatsD
// client. Tests declare what they need on it, so a wire assertion never depends
// on a real subsystem metric keeping its name.
func newWireCapture(t *testing.T) *wireCapture {
	t.Helper()
	socket, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	// FlushSecs must be positive: the log ticker is built unconditionally and
	// time.NewTicker panics on zero. No API key, so no log ever leaves.
	client, err := datadog.NewClient(datadog.Config{
		Env:          "test",
		Service:      "svc",
		StatsdAddr:   socket.LocalAddr().String(),
		FlushSecs:    3600,
		MaxBatchSize: 1,
	}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		socket.Close()
		t.Fatal(err)
	}
	if client.Statsd == nil {
		client.Close()
		socket.Close()
		t.Fatal("no DogStatsD client; the UDP listener should always connect")
	}
	t.Cleanup(func() {
		client.Close()
		socket.Close()
	})
	m := &Metrics{
		sinks:  &sinks{dd: dogstatsd{client: client}, logger: slog.New(slog.NewTextHandler(io.Discard, nil))},
		byName: make(map[string]*declaration),
	}
	return &wireCapture{metrics: m, client: client, socket: socket}
}

// sample is one parsed datagram line.
type sample struct {
	name  string
	value string
	kind  string
	tags  map[string]string
}

// samples flushes the client and parses everything the listener received.
func (w *wireCapture) samples(t *testing.T) []sample {
	t.Helper()
	if err := w.client.Statsd.Flush(); err != nil {
		t.Fatal(err)
	}
	if err := w.socket.SetReadDeadline(time.Now().Add(500 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 8192)
	var raw strings.Builder
	for {
		n, _, err := w.socket.ReadFrom(buf)
		if err != nil {
			var netErr net.Error
			if errors.As(err, &netErr) && netErr.Timeout() {
				break
			}
			t.Fatal(err)
		}
		raw.Write(buf[:n])
	}
	var out []sample
	for _, line := range strings.Split(raw.String(), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		parts := strings.Split(line, "|")
		nameValue := strings.SplitN(parts[0], ":", 2)
		if len(parts) < 2 || len(nameValue) != 2 {
			t.Fatalf("unparseable datagram %q", line)
		}
		s := sample{name: nameValue[0], value: nameValue[1], kind: parts[1], tags: map[string]string{}}
		for _, part := range parts[2:] {
			if !strings.HasPrefix(part, "#") {
				continue
			}
			for _, tag := range strings.Split(strings.TrimPrefix(part, "#"), ",") {
				kv := strings.SplitN(tag, ":", 2)
				if len(kv) == 2 {
					s.tags[kv[0]] = kv[1]
				} else {
					s.tags[kv[0]] = ""
				}
			}
		}
		out = append(out, s)
	}
	return out
}

// only returns the single sample for a metric name out of an already-drained
// batch, failing if the count is not one. Datadog aggregates counters and gauges
// client-side per (name, tag set), so "how many datagrams" is itself part of what
// these tests pin down.
//
// It takes the batch rather than reading the socket because a read drains it:
// call samples() once per test and assert against the result.
func only(t *testing.T, batch []sample, name string) sample {
	t.Helper()
	var found []sample
	for _, s := range batch {
		if s.name == name {
			found = append(found, s)
		}
	}
	if len(found) != 1 {
		t.Fatalf("%s: got %d datagrams, want 1: %+v", name, len(found), found)
	}
	return found[0]
}

// TestKindsReachTheWireAsDeclared pins each Kind to its wire type. A count is
// `c`, a gauge is `g`, and a distribution is `d` — not `h`, which would make the
// agent compute the percentiles instead of the intake.
func TestKindsReachTheWireAsDeclared(t *testing.T) {
	w := newWireCapture(t)
	counter := w.metrics.counter("test.count", "help", "outcome")
	gauge := w.metrics.gauge("test.gauge", "help")
	dist := w.metrics.distribution("test.dist", "help", "op")

	counter.Add(3, "ok")
	gauge.Set(7)
	dist.Observe(12.5, "read")

	batch := w.samples(t)
	for _, tc := range []struct {
		name, value, kind string
		tags              map[string]string
	}{
		{"d_inference.test.count", "3", "c", map[string]string{"outcome": "ok"}},
		{"d_inference.test.gauge", "7", "g", nil},
		{"d_inference.test.dist", "12.5", "d", map[string]string{"op": "read"}},
	} {
		got := only(t, batch, tc.name)
		if got.value != tc.value || got.kind != tc.kind {
			t.Errorf("%s = %s|%s, want %s|%s", tc.name, got.value, got.kind, tc.value, tc.kind)
		}
		for key, want := range tc.tags {
			if got.tags[key] != want {
				t.Errorf("%s tag %s = %q, want %q (all: %v)", tc.name, key, got.tags[key], want, got.tags)
			}
		}
		// The client's global tags come from Config and must survive the
		// per-call tag list, since every dashboard scopes on them.
		if got.tags["env"] != "test" || got.tags["service"] != "svc" {
			t.Errorf("%s lost the global tags: %v", tc.name, got.tags)
		}
	}
}

// TestEmptyLabelValueOmitsTheTag covers the conditional-dimension case. A metric
// like ws.disconnects carries a close code only for a peer-initiated close; the
// alternative to omitting the tag is a `code:` tag whose value is the empty
// string, which is a second series in every query that groups by code.
func TestEmptyLabelValueOmitsTheTag(t *testing.T) {
	w := newWireCapture(t)
	counter := w.metrics.counter("test.conditional", "help", "reason", "code")

	counter.Inc("read_error", "")

	got := only(t, w.samples(t), "d_inference.test.conditional")
	if got.tags["reason"] != "read_error" {
		t.Errorf("reason = %q, want read_error", got.tags["reason"])
	}
	if _, present := got.tags["code"]; present {
		t.Errorf("an empty label value produced a tag anyway: %v", got.tags)
	}
}

// TestNoDatagramsWithoutRecording is the guard on the migration's blast radius:
// declaring a metric must not, by itself, put anything on the wire. A catalog is
// built at startup with hundreds of declarations, and a declaration that emitted
// a zero would create every series immediately — including the ones whose call
// sites are unreachable in a given deployment.
func TestNoDatagramsWithoutRecording(t *testing.T) {
	w := newWireCapture(t)
	w.metrics.counter("test.never", "help")
	w.metrics.gauge("test.never_gauge", "help")
	w.metrics.distribution("test.never_dist", "help")

	if got := w.samples(t); len(got) != 0 {
		t.Errorf("declaration alone emitted %d datagrams: %+v", len(got), got)
	}
}
