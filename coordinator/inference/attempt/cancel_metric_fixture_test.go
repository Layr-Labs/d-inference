package attempt

import (
	"log/slog"
	"net"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/datadog"
)

// udpCollector listens on a random UDP port and collects DogStatsD packets.
type udpCollector struct {
	conn    *net.UDPConn
	packets chan string
	done    chan struct{}
}

func newUDPCollector(t *testing.T) *udpCollector {
	t.Helper()
	addr, err := net.ResolveUDPAddr("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		t.Fatal(err)
	}
	c := &udpCollector{
		conn:    conn,
		packets: make(chan string, 256),
		done:    make(chan struct{}),
	}
	go func() {
		defer close(c.done)
		buf := make([]byte, 8192)
		for {
			n, _, err := conn.ReadFromUDP(buf)
			if err != nil {
				return
			}
			for _, line := range strings.Split(string(buf[:n]), "\n") {
				line = strings.TrimSpace(line)
				if line != "" {
					c.packets <- line
				}
			}
		}
	}()
	return c
}

func (c *udpCollector) Addr() string {
	return c.conn.LocalAddr().String()
}

func (c *udpCollector) Close() {
	c.conn.Close()
	<-c.done
}

func (c *udpCollector) drain() []string {
	time.Sleep(200 * time.Millisecond)
	var out []string
	for {
		select {
		case p := <-c.packets:
			out = append(out, p)
		default:
			return out
		}
	}
}

func findMetrics(packets []string, substr string) []string {
	var out []string
	for _, p := range packets {
		if strings.Contains(p, substr) {
			out = append(out, p)
		}
	}
	return out
}

func newTestDD(t *testing.T, collector *udpCollector) *datadog.Client {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	// Use datadog.NewClient with a config pointing at our collector so all
	// internal fields (logTicker, logDone, etc.) are properly initialized.
	cfg := datadog.Config{
		StatsdAddr: collector.Addr(),
		FlushSecs:  60,
	}
	client, err := datadog.NewClient(cfg, logger)
	if err != nil {
		t.Fatal(err)
	}
	return client
}

func requireMetricWithTags(t *testing.T, packets []string, name string, tags ...string) []string {
	t.Helper()
	var matched []string
	for _, p := range findMetrics(packets, name) {
		ok := true
		for _, tag := range tags {
			if !strings.Contains(p, tag) {
				ok = false
				break
			}
		}
		if ok {
			matched = append(matched, p)
		}
	}
	if len(matched) == 0 {
		t.Fatalf("no %s packet carrying %v; packets=%v", name, tags, findMetrics(packets, name))
	}
	return matched
}
