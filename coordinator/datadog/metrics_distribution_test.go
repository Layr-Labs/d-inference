package datadog

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/DataDog/datadog-go/v5/statsd"
)

// wireDist decodes the distribution_points payload independently of
// ddDistribution, so renaming a JSON tag fails a test instead of silently
// shipping a field the intake ignores.
type wireDist struct {
	Metric string   `json:"metric"`
	Points [][]any  `json:"points"`
	Type   string   `json:"type"`
	Tags   []string `json:"tags"`
	Host   string   `json:"host"`
}

func (w wireDist) values(t *testing.T) []float64 {
	t.Helper()
	if len(w.Points) != 1 {
		t.Fatalf("%s: want 1 point, got %d", w.Metric, len(w.Points))
	}
	if len(w.Points[0]) != 2 {
		t.Fatalf("%s: a point is [timestamp, [values]], got %v", w.Metric, w.Points[0])
	}
	// The intake documents the timestamp as a number and rejects a string, and
	// nothing else here would notice a formatted one: encoding/json decodes a
	// JSON number into float64 and a quoted one into string.
	if _, ok := w.Points[0][0].(float64); !ok {
		t.Fatalf("%s: timestamp must be a JSON number, got %#v", w.Metric, w.Points[0][0])
	}
	raw, ok := w.Points[0][1].([]any)
	if !ok {
		t.Fatalf("%s: point payload is not an array of values: %#v", w.Metric, w.Points[0][1])
	}
	out := make([]float64, 0, len(raw))
	for _, v := range raw {
		f, ok := v.(float64)
		if !ok {
			t.Fatalf("%s: non-numeric value %#v", w.Metric, v)
		}
		out = append(out, f)
	}
	return out
}

// distIntake is an httptest server that records every distribution_points POST.
type distIntake struct {
	*httptest.Server
	mu       sync.Mutex
	requests [][]wireDist
	keys     []string
	status   int
	body     string
}

func newDistIntake(t *testing.T) *distIntake {
	t.Helper()
	d := &distIntake{status: http.StatusAccepted}
	d.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		var payload struct {
			Series []wireDist `json:"series"`
		}
		if err := json.Unmarshal(raw, &payload); err != nil {
			t.Errorf("intake got undecodable body %q: %v", raw, err)
		}
		d.mu.Lock()
		d.requests = append(d.requests, payload.Series)
		d.keys = append(d.keys, r.Header.Get("Dd-Api-Key"))
		status, body := d.status, d.body
		d.mu.Unlock()
		w.WriteHeader(status)
		if body != "" {
			_, _ = w.Write([]byte(body))
		}
	}))
	t.Cleanup(d.Close)
	return d
}

func (d *distIntake) series() []wireDist {
	d.mu.Lock()
	defer d.mu.Unlock()
	var out []wireDist
	for _, batch := range d.requests {
		out = append(out, batch...)
	}
	return out
}

// batches returns the recorded requests, one entry per POST.
func (d *distIntake) batches() [][]wireDist {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([][]wireDist(nil), d.requests...)
}

func (d *distIntake) count() int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return len(d.requests)
}

func quietLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
}

func distClient(intake *distIntake, apiKey string) *Client {
	return &Client{
		logger:      quietLogger(),
		apiKey:      apiKey,
		httpClient:  intake.Client(),
		distURL:     intake.URL,
		dist:        newDistBuffer(),
		metricsHost: "d-inference-coordinator",
		metricsTags: []string{"env:production", "service:d-inference-coordinator"},
	}
}

// TestHistogramSubmitsDistributionWithoutAgent is the regression for the empty
// latency panels. A UDP socket is opened and listened on so the DogStatsD leg
// would visibly succeed if it were still chosen — on prod nothing listens, and
// the datagrams vanish with no error, which is how this went unnoticed.
func TestHistogramSubmitsDistributionWithoutAgent(t *testing.T) {
	socket, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer socket.Close()
	sd, err := statsd.New(socket.LocalAddr().String(), statsd.WithNamespace("d_inference."), statsd.WithoutTelemetry())
	if err != nil {
		t.Fatal(err)
	}
	defer sd.Close()

	intake := newDistIntake(t)
	c := distClient(intake, "test-key")
	c.Statsd = sd

	tags := []string{"path:/v1/chat/completions"}
	for _, v := range []float64{12, 40, 7} {
		c.Histogram("http.latency_ms", v, tags)
	}
	c.flushDistributions()
	if err := sd.Flush(); err != nil {
		t.Fatal(err)
	}

	got := intake.series()
	if len(got) != 1 {
		t.Fatalf("want 1 distribution series, got %d: %+v", len(got), got)
	}
	d := got[0]
	if d.Metric != "d_inference.http.latency_ms" {
		t.Errorf("metric = %q, want the DogStatsD namespace prefix and no aggregate suffix", d.Metric)
	}
	if d.Type != "distribution" {
		t.Errorf("type = %q, want distribution", d.Type)
	}
	if d.Host != "d-inference-coordinator" {
		t.Errorf("host = %q", d.Host)
	}
	// Raw values, in submission order and un-aggregated: the whole point is that
	// Datadog computes the percentiles, so nothing here may pre-summarize.
	if want := []float64{12, 40, 7}; !equalFloats(d.values(t), want) {
		t.Errorf("values = %v, want %v", d.values(t), want)
	}
	// env/service from metricsTags, then the caller's own tags.
	if joined := strings.Join(d.Tags, ","); joined != "env:production,service:d-inference-coordinator,path:/v1/chat/completions" {
		t.Errorf("tags = %q", joined)
	}
	if key := intake.keys[0]; key != "test-key" {
		t.Errorf("Dd-Api-Key = %q", key)
	}

	// And the UDP leg is skipped, not teed — an agent appearing later must not
	// double-count. This is the same rule httpMetrics applies to gauges.
	if leaked := readUDP(t, socket); leaked != "" {
		t.Errorf("histogram was duplicated over DogStatsD: %s", leaked)
	}
}

// TestHistogramUsesDogStatsDWithoutAPIKey pins the other half: an agent-only
// deployment must keep working exactly as before.
func TestHistogramUsesDogStatsDWithoutAPIKey(t *testing.T) {
	socket, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer socket.Close()
	sd, err := statsd.New(socket.LocalAddr().String(), statsd.WithNamespace("d_inference."), statsd.WithoutTelemetry())
	if err != nil {
		t.Fatal(err)
	}
	defer sd.Close()

	intake := newDistIntake(t)
	c := distClient(intake, "") // no API key
	c.Statsd = sd

	c.Histogram("http.latency_ms", 12, []string{"path:/health"})
	c.flushDistributions()
	if err := sd.Flush(); err != nil {
		t.Fatal(err)
	}

	if n := intake.count(); n != 0 {
		t.Fatalf("agent-only client posted %d distribution request(s)", n)
	}
	packets := readUDP(t, socket)
	if !strings.Contains(packets, "d_inference.http.latency_ms:12|h|#path:/health") {
		t.Errorf("DogStatsD histogram missing: %q", packets)
	}
}

// TestDistributionSeriesSplitByTags: percentiles are per tag set, so two paths
// must not be merged into one series (seriesKey is shared with metrics_http.go).
func TestDistributionSeriesSplitByTags(t *testing.T) {
	intake := newDistIntake(t)
	c := distClient(intake, "k")

	c.Histogram("http.latency_ms", 1, []string{"path:/health"})
	c.Histogram("http.latency_ms", 2, []string{"path:/v1/models"})
	c.Histogram("http.latency_ms", 3, []string{"path:/health"})
	c.flushDistributions()

	byPath := map[string][]float64{}
	for _, d := range intake.series() {
		byPath[d.Tags[len(d.Tags)-1]] = d.values(t)
	}
	if got := byPath["path:/health"]; !equalFloats(got, []float64{1, 3}) {
		t.Errorf("/health values = %v, want [1 3]", got)
	}
	if got := byPath["path:/v1/models"]; !equalFloats(got, []float64{2}) {
		t.Errorf("/v1/models values = %v, want [2]", got)
	}
}

// TestDistributionBufferDrains: a flushed window must not be resubmitted, or
// every value would be counted once per flush for as long as the process runs.
func TestDistributionBufferDrains(t *testing.T) {
	intake := newDistIntake(t)
	c := distClient(intake, "k")

	c.Histogram("inference.ttft_ms", 100, nil)
	c.flushDistributions()
	c.flushDistributions()

	if n := intake.count(); n != 1 {
		t.Fatalf("flush count = %d, want 1 (the second flush had nothing to send)", n)
	}
}

// TestDistributionReservoirBoundsWindow: an unbounded value slice per series is
// a heap leak on a burst. Past the cap the window is sampled, which keeps
// percentiles unbiased but makes count/sum under-report — so it is reported.
func TestDistributionReservoirBoundsWindow(t *testing.T) {
	intake := newDistIntake(t)
	var logs bytes.Buffer
	c := distClient(intake, "k")
	c.logger = slog.New(slog.NewTextHandler(&logs, &slog.HandlerOptions{Level: slog.LevelWarn}))

	const observations = maxDistValuesPerSeries * 3
	for i := range observations {
		c.Histogram("store.debit.latency_ms", float64(i), []string{"op:charge"})
	}
	c.flushDistributions()

	got := intake.series()
	if len(got) != 1 {
		t.Fatalf("want 1 series, got %d", len(got))
	}
	values := got[0].values(t)
	if len(values) != maxDistValuesPerSeries {
		t.Errorf("submitted %d values, want the cap %d", len(values), maxDistValuesPerSeries)
	}
	// Every surviving value must be a real observation, and the sample must not
	// have collapsed to the first window (which truncation would produce).
	seen := map[float64]bool{}
	var above int
	for _, v := range values {
		if v < 0 || v >= observations || v != float64(int(v)) {
			t.Fatalf("fabricated value %v", v)
		}
		if seen[v] {
			t.Fatalf("value %v submitted twice", v)
		}
		seen[v] = true
		if v >= maxDistValuesPerSeries {
			above++
		}
	}
	if above == 0 {
		t.Error("sample contains nothing past the cap; the window was truncated, not sampled")
	}
	if out := logs.String(); !strings.Contains(out, "distribution window sampled") {
		t.Errorf("sampling was not reported: %q", out)
	}
}

// TestDistributionChunksOversizedFlush: the intake rejects payloads over
// 3.2 MB, so one flush with many full series must span requests rather than
// earn a 413 for the whole window.
func TestDistributionChunksOversizedFlush(t *testing.T) {
	intake := newDistIntake(t)
	c := distClient(intake, "k")

	series := (maxDistValuesPerRequest / maxDistValuesPerSeries) + 5
	for s := range series {
		tags := []string{"op:" + strconv.Itoa(s)}
		for i := range maxDistValuesPerSeries {
			c.Histogram("store.debit.latency_ms", float64(i), tags)
		}
	}
	c.flushDistributions()

	if n := intake.count(); n < 2 {
		t.Fatalf("%d value(s) across %d series went out in %d request(s); want a split",
			series*maxDistValuesPerSeries, series, n)
	}
	if got := len(intake.series()); got != series {
		t.Errorf("chunking lost series: sent %d, intake saw %d", series, got)
	}
}

// TestDistributionChunksManyThinSeries: value count alone does not bound the
// payload. A flush of one-value series is almost entirely metric names, tags and
// host, so 50k values spread over 50k series is ~14 MB — well past the intake
// limit — while never tripping maxDistValuesPerRequest.
func TestDistributionChunksManyThinSeries(t *testing.T) {
	intake := newDistIntake(t)
	c := distClient(intake, "k")

	// Enough entries to exceed the byte bound, with a value count that stays far
	// under maxDistValuesPerRequest so only the byte bound can split this.
	series := (maxDistBytesPerRequest / distEntryBytes) + 100
	if series >= maxDistValuesPerRequest {
		t.Fatalf("test cannot isolate the byte bound: %d series >= %d values", series, maxDistValuesPerRequest)
	}
	for s := range series {
		c.Histogram("registry.gate.wait_ms", 1, []string{"provider_id:" + strconv.Itoa(s)})
	}
	c.flushDistributions()

	if n := intake.count(); n < 2 {
		t.Fatalf("%d thin series went out in %d request(s); want a split on bytes", series, n)
	}
	if got := len(intake.series()); got != series {
		t.Errorf("chunking lost series: sent %d, intake saw %d", series, got)
	}
	// The point of the split: no single request may approach the intake limit.
	for i, batch := range intake.batches() {
		body, err := json.Marshal(map[string]any{"series": batch})
		if err != nil {
			t.Fatal(err)
		}
		if len(body) > maxDistBytesPerRequest {
			t.Errorf("request %d is %d bytes, over the %d-byte bound", i, len(body), maxDistBytesPerRequest)
		}
	}
}

// TestFlushDistributionsWithoutLogger: a Client can be assembled by hand without
// a logger (tests, embedders), and a dropped metric must not become a panic on
// the two paths that report — a rejected batch and a sampled window.
func TestFlushDistributionsWithoutLogger(t *testing.T) {
	intake := newDistIntake(t)
	intake.status = http.StatusForbidden
	intake.body = `{"errors":["Forbidden"]}`

	c := distClient(intake, "k")
	c.logger = nil

	tags := []string{"op:debit"}
	for i := range maxDistValuesPerSeries + 1 { // force the sampling report too
		c.Histogram("store.debit.latency_ms", float64(i), tags)
	}
	c.flushDistributions() // must not panic

	if intake.count() != 1 {
		t.Fatalf("want 1 request, got %d", intake.count())
	}
}

// TestFlushDistributionsReportsRejection: a rejected window must say why, the
// same as the logs and series intakes.
func TestFlushDistributionsReportsRejection(t *testing.T) {
	intake := newDistIntake(t)
	intake.mu.Lock()
	intake.status, intake.body = http.StatusForbidden, `{"errors":["Forbidden"]}`
	intake.mu.Unlock()

	var logs bytes.Buffer
	c := distClient(intake, "bad-key")
	c.logger = slog.New(slog.NewTextHandler(&logs, &slog.HandlerOptions{Level: slog.LevelWarn}))

	c.Histogram("http.latency_ms", 1, nil)
	c.flushDistributions()

	out := logs.String()
	for _, want := range []string{"distribution API returned error", "403", "Forbidden"} {
		if !strings.Contains(out, want) {
			t.Errorf("report omits %q: %q", want, out)
		}
	}
}

// TestFlushDistributionsQuietOnSuccess: the warning must be about a rejection,
// not about every flush.
func TestFlushDistributionsQuietOnSuccess(t *testing.T) {
	intake := newDistIntake(t)
	var logs bytes.Buffer
	c := distClient(intake, "k")
	c.logger = slog.New(slog.NewTextHandler(&logs, &slog.HandlerOptions{Level: slog.LevelWarn}))

	c.Histogram("http.latency_ms", 1, nil)
	c.flushDistributions()

	if logs.Len() != 0 {
		t.Errorf("202 produced log output: %q", logs.String())
	}
}

// TestNewClientWiresDistributions covers the wiring the other tests stub out:
// they set distURL and dist by hand, so deleting either assignment in NewClient
// would leave them all passing while shipping histograms to a dead UDP socket.
func TestNewClientWiresDistributions(t *testing.T) {
	c, err := NewClient(Config{
		APIKey:       "k",
		Site:         "datadoghq.com",
		Env:          "production",
		Service:      "d-inference-coordinator",
		StatsdAddr:   "127.0.0.1:8125", // UDP, no listener needed
		FlushSecs:    5,
		MaxBatchSize: 100,
	}, quietLogger())
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	defer c.Close()

	if c.distURL != "https://api.datadoghq.com/api/v1/distribution_points" {
		t.Errorf("distURL = %q", c.distURL)
	}
	if !c.httpDistributions() {
		t.Fatal("httpDistributions false with an API key: histograms would go to DogStatsD")
	}
	c.Histogram("http.latency_ms", 42, []string{"path:/health"})
	if got := c.dist.drain(); len(got) != 1 || len(got[0].values) != 1 || got[0].values[0] != 42 {
		t.Errorf("Histogram did not reach the distribution buffer: %+v", got)
	}
}

// TestHistogramNilSafe: ddHistogram guards on a nil Server.dd, but a Client
// assembled without a distribution buffer (any hand-built one) must fall back
// rather than panic.
func TestHistogramNilSafe(t *testing.T) {
	var nilClient *Client
	nilClient.Histogram("x", 1, nil)                                   // nil receiver
	(&Client{apiKey: "k"}).Histogram("x", 1, nil)                      // key set, no buffer, no statsd
	(&Client{}).Histogram("x", 1, nil)                                 // nothing configured
	nilClient.flushDistributions()                                     // nil receiver
	(&Client{apiKey: "k", logger: quietLogger()}).flushDistributions() // no buffer
}

func equalFloats(a, b []float64) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// readUDP drains whatever is waiting on the socket within a short deadline.
func readUDP(t *testing.T, socket net.PacketConn) string {
	t.Helper()
	if err := socket.SetReadDeadline(time.Now().Add(100 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 4096)
	var out strings.Builder
	for {
		n, _, err := socket.ReadFrom(buf)
		if err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				return out.String()
			}
			t.Fatal(err)
		}
		out.Write(buf[:n])
	}
}
