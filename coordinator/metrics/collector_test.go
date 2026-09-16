package metrics

import (
	"bytes"
	"log/slog"
	"strings"
	"testing"
)

// recorded is one sample as a fake sink saw it. These tests are about the
// declaration's bookkeeping — tag pairing, mirror narrowing, what is dropped —
// so they read the arguments rather than the datagram; wire_test.go covers the
// bytes.
type recorded struct {
	kind  Kind
	name  string
	value float64
	tags  []string
}

type fakeSink struct{ samples []recorded }

func (f *fakeSink) Count(name string, value int64, tags []string) {
	f.samples = append(f.samples, recorded{KindCount, name, float64(value), tags})
}

func (f *fakeSink) Gauge(name string, value float64, tags []string) {
	f.samples = append(f.samples, recorded{KindGauge, name, value, tags})
}

func (f *fakeSink) Distribution(name string, value float64, tags []string) {
	f.samples = append(f.samples, recorded{KindDistribution, name, value, tags})
}

type mirrored struct {
	name   string
	value  float64
	labels []Label
}

type fakeMirror struct {
	counters   []mirrored
	histograms []mirrored
}

func (f *fakeMirror) AddCounter(name string, delta int64, labels ...Label) {
	f.counters = append(f.counters, mirrored{name, float64(delta), labels})
}

func (f *fakeMirror) ObserveHistogram(name string, value float64, labels ...Label) {
	f.histograms = append(f.histograms, mirrored{name, value, labels})
}

// newFakeCatalog is an empty catalog over fakes, so a test declares exactly the
// shape it is about.
func newFakeCatalog() (*Metrics, *fakeSink, *fakeMirror, *bytes.Buffer) {
	sink := &fakeSink{}
	mirror := &fakeMirror{}
	logs := &bytes.Buffer{}
	m := &Metrics{
		sinks: &sinks{
			dd:     sink,
			mirror: mirror,
			logger: slog.New(slog.NewTextHandler(logs, nil)),
		},
		byName: make(map[string]*declaration),
	}
	return m, sink, mirror, logs
}

// TestCounterDropsNonPositiveDeltas covers the transport's asymmetry. On this
// path a sample is a delta the intake sums, and the producers of a delta are
// differences of cumulative provider counters — a provider that restarted has a
// negative difference, which as a delta would subtract work that did happen.
func TestCounterDropsNonPositiveDeltas(t *testing.T) {
	m, sink, mirror, _ := newFakeCatalog()
	counter := m.mirroredCounter("test.count", "test_count_total", "help")

	counter.Add(0)
	counter.Add(-5)
	if len(sink.samples) != 0 || len(mirror.counters) != 0 {
		t.Fatalf("a non-positive delta was recorded: %+v / %+v", sink.samples, mirror.counters)
	}

	counter.Add(2)
	counter.Inc()
	if len(sink.samples) != 2 || sink.samples[0].value != 2 || sink.samples[1].value != 1 {
		t.Fatalf("positive deltas not recorded as passed: %+v", sink.samples)
	}
}

// TestMirrorNarrowsToItsOwnLabels is the reason mirrorPrefix exists.
// ws_disconnects_total is a stored series tagged by reason alone, while
// ws.disconnects splits by close code as well. Passing the full value list to the
// mirror would widen its key set, which for the in-process registry means the
// existing series stops being the one anything queried.
func TestMirrorNarrowsToItsOwnLabels(t *testing.T) {
	m, sink, mirror, _ := newFakeCatalog()
	counter := m.mirroredCounter("test.disconnects", "test_disconnects_total", "help", "reason", "code")
	counter.mirrorPrefix = 1

	counter.Inc("peer_close", "1000")

	if got := sink.samples[0].tags; len(got) != 2 || got[0] != "reason:peer_close" || got[1] != "code:1000" {
		t.Errorf("Datadog tags = %v, want both keys", got)
	}
	if len(mirror.counters) != 1 {
		t.Fatalf("mirror got %d samples, want 1", len(mirror.counters))
	}
	labels := mirror.counters[0].labels
	if len(labels) != 1 || labels[0] != (Label{Name: "reason", Value: "peer_close"}) {
		t.Errorf("mirror labels = %v, want reason only", labels)
	}
	if mirror.counters[0].name != "test_disconnects_total" {
		t.Errorf("mirror name = %q", mirror.counters[0].name)
	}
}

// TestUnmirroredCollectorNeverTouchesTheMirror: most declarations have no
// mirror, and the in-process registry must not grow names nobody registered
// there.
func TestUnmirroredCollectorNeverTouchesTheMirror(t *testing.T) {
	m, _, mirror, _ := newFakeCatalog()
	m.counter("test.count", "help").Inc()
	m.distribution("test.dist", "help").Observe(1)

	if len(mirror.counters) != 0 || len(mirror.histograms) != 0 {
		t.Errorf("mirror was written to: %+v / %+v", mirror.counters, mirror.histograms)
	}
}

// TestDistributionMirrorsAsHistogram: the in-process registry's word for a
// distribution is a histogram, and the pairing is by declaration, not by name.
func TestDistributionMirrorsAsHistogram(t *testing.T) {
	m, sink, mirror, _ := newFakeCatalog()
	m.mirroredDistribution("test.latency_ms", "test_latency_ms", "help", "op").Observe(42, "read")

	if len(sink.samples) != 1 || sink.samples[0].kind != KindDistribution {
		t.Fatalf("dd side = %+v", sink.samples)
	}
	if len(mirror.histograms) != 1 || mirror.histograms[0].value != 42 {
		t.Fatalf("mirror histograms = %+v", mirror.histograms)
	}
	if len(mirror.counters) != 0 {
		t.Errorf("a distribution incremented a counter: %+v", mirror.counters)
	}
}

// TestArityMismatchIsReportedOnceAndStillRecords covers the deliberate choice
// not to fail closed. A call site passing the wrong number of label values is a
// programming error, but telemetry does not get to panic a request path, and
// dropping the sample would hide the drift the declaration exists to catch. So:
// record what can be paired, report once per metric.
func TestArityMismatchIsReportedOnceAndStillRecords(t *testing.T) {
	m, sink, _, logs := newFakeCatalog()
	counter := m.counter("test.count", "help", "reason", "code")

	counter.Inc("only_reason")
	counter.Inc("only_reason")
	counter.Inc("reason", "code", "extra")

	if len(sink.samples) != 3 {
		t.Fatalf("samples were dropped on arity mismatch: %+v", sink.samples)
	}
	// Too few values pairs what it has; too many are truncated to the declared
	// keys rather than emitting an unkeyed tag.
	if got := sink.samples[0].tags; len(got) != 1 || got[0] != "reason:only_reason" {
		t.Errorf("short call tags = %v", got)
	}
	if got := sink.samples[2].tags; len(got) != 2 || got[1] != "code:code" {
		t.Errorf("long call tags = %v", got)
	}
	if n := strings.Count(logs.String(), "label arity mismatch"); n != 1 {
		t.Errorf("arity mismatch logged %d times, want 1:\n%s", n, logs.String())
	}
}

// TestArityIsPerMetric: the once-per-metric report must not be once per process,
// or the first mis-tagged metric would mask every other one.
func TestArityIsPerMetric(t *testing.T) {
	m, _, _, logs := newFakeCatalog()
	m.counter("test.one", "help", "a").Inc()
	m.counter("test.two", "help", "a").Inc()

	if n := strings.Count(logs.String(), "label arity mismatch"); n != 2 {
		t.Errorf("logged %d times across two metrics, want 2:\n%s", n, logs.String())
	}
}

// TestNoopRecordsNowhere: Noop is not a mode anyone selects — it is what a host
// with no agent and every test gets — so it has to be exercisable on every
// collector without a nil check anywhere.
func TestNoopRecordsNowhere(t *testing.T) {
	m := Noop()
	m.Trust.Failures.Inc("timeout")
	m.Session.Disconnects.Inc("read_error", "")
	m.Billing.Reservations.Inc("model", "mode", "ok")
	m.Store.DebitLatencyMs.Observe(12, "debit")
	m.Store.CacheHits.Set(3, "user")

	if m.sinks.mirror != nil {
		t.Error("Noop has a mirror; it should record nowhere at all")
	}
}

// TestDuplicateDeclarationPanics: two declarations of one name are two call-site
// views of a single series, which is the exact failure this package exists to
// prevent. It has to be loud, and it is safe to be loud because declarations are
// static — TestCatalogIsWellFormed reaches it before a process would.
func TestDuplicateDeclarationPanics(t *testing.T) {
	m, _, _, _ := newFakeCatalog()
	m.counter("test.count", "help")

	defer func() {
		r := recover()
		if r == nil {
			t.Fatal("a duplicate name did not panic")
		}
		if !strings.Contains(r.(string), "test.count") {
			t.Errorf("panic does not name the metric: %v", r)
		}
	}()
	m.gauge("test.count", "a different view of the same series")
}
