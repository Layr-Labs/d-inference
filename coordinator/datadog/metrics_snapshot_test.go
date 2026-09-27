package datadog

import (
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/DataDog/datadog-go/v5/statsd"
)

func TestHistogramOrGaugeUsesConfiguredTransport(t *testing.T) {
	for _, apiKey := range []string{"", "test-api-key"} {
		name := "dogstatsd"
		if apiKey != "" {
			name = "http-with-non-nil-statsd"
		}
		t.Run(name, func(t *testing.T) {
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
			type submission struct {
				body []byte
				key  string
			}
			requests := make(chan submission, 1)
			intake := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				body, _ := io.ReadAll(r.Body)
				requests <- submission{body: body, key: r.Header.Get("Dd-Api-Key")}
				w.WriteHeader(http.StatusAccepted)
			}))
			defer intake.Close()
			c := &Client{
				Statsd: sd, logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
				apiKey: apiKey, httpClient: intake.Client(), seriesURL: intake.URL,
				series: newSeriesBuffer(), flushIntervalSecs: 5,
			}
			tags := []string{"chip_family:M3", "provider_version:0.8.x"}
			c.HistogramOrGauge("provider.mlx_memory.active_gb", 8, tags)
			c.HistogramOrGauge("provider.mlx_memory.active_gb", 12, tags)
			c.flushSeries()
			if err := sd.Flush(); err != nil {
				t.Fatal(err)
			}
			if apiKey != "" {
				var request submission
				select {
				case request = <-requests:
				default:
					t.Fatal("snapshot was not submitted over HTTP")
				}
				var body struct {
					Series []ddMetric `json:"series"`
				}
				if err := json.Unmarshal(request.body, &body); err != nil {
					t.Fatal(err)
				}
				if request.key != apiKey || len(body.Series) != 1 {
					t.Fatalf("unexpected HTTP snapshot: key=%q series=%+v", request.key, body.Series)
				}
				metric := body.Series[0]
				if metric.Metric != "d_inference.provider.mlx_memory.active_gb" || metric.Type != "gauge" || len(metric.Points) != 1 || metric.Points[0][1] != 12 {
					t.Fatalf("expected latest-value gauge: %+v", metric)
				}
				if strings.Join(metric.Tags, ",") != strings.Join(tags, ",") {
					t.Fatalf("snapshot tags changed: %v", metric.Tags)
				}
			} else {
				select {
				case request := <-requests:
					t.Fatalf("DogStatsD-only snapshot unexpectedly used HTTP: %s", request.body)
				default:
				}
			}
			if err := socket.SetReadDeadline(time.Now().Add(100 * time.Millisecond)); err != nil {
				t.Fatal(err)
			}
			buf := make([]byte, 4096)
			var packets strings.Builder
			for {
				n, _, err := socket.ReadFrom(buf)
				if err != nil {
					if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
						break
					}
					t.Fatal(err)
				}
				packets.Write(buf[:n])
			}
			if apiKey != "" {
				if packets.Len() != 0 {
					t.Fatalf("HTTP snapshots were duplicated over UDP: %s", packets.String())
				}
			} else {
				for _, value := range []string{"8", "12"} {
					if !strings.Contains(packets.String(), "d_inference.provider.mlx_memory.active_gb:"+value+"|h|#"+strings.Join(tags, ",")) {
						t.Fatalf("missing histogram value %s: %s", value, packets.String())
					}
				}
			}
		})
	}
}
