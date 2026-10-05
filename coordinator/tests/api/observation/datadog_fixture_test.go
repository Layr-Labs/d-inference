package observation_test

import (
	"net"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/datadog"
)

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
	c := &udpCollector{conn: conn, packets: make(chan string, 256), done: make(chan struct{})}
	go func() {
		defer close(c.done)
		buf := make([]byte, 8192)
		for {
			n, _, err := conn.ReadFromUDP(buf)
			if err != nil {
				return
			}
			for _, line := range strings.Split(string(buf[:n]), "\n") {
				if line = strings.TrimSpace(line); line != "" {
					c.packets <- line
				}
			}
		}
	}()
	return c
}

func (c *udpCollector) Close() { c.conn.Close(); <-c.done }

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

func newTestDD(t *testing.T, collector *udpCollector) *datadog.Client {
	t.Helper()
	client, err := datadog.NewClient(datadog.Config{StatsdAddr: collector.conn.LocalAddr().String(), FlushSecs: 60}, quietLogger())
	if err != nil {
		t.Fatal(err)
	}
	return client
}

func hasMetric(packets []string, substr string) bool {
	return len(findMetrics(packets, substr)) > 0
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

func metricSampleValue(t *testing.T, packet string) float64 {
	t.Helper()
	colon, pipe := strings.Index(packet, ":"), strings.Index(packet, "|")
	if colon < 0 || pipe < 0 || pipe <= colon {
		t.Fatalf("unparseable DogStatsD packet %q", packet)
	}
	v, err := strconv.ParseFloat(packet[colon+1:pipe], 64)
	if err != nil {
		t.Fatalf("packet %q: bad value: %v", packet, err)
	}
	return v
}

func sumMetric(t *testing.T, packets []string, metric string, tags ...string) float64 {
	t.Helper()
	total := 0.0
	for _, p := range packets {
		if !strings.Contains(p, metric+":") {
			continue
		}
		match := true
		for _, tag := range tags {
			if !strings.Contains(p, tag) {
				match = false
				break
			}
		}
		if match {
			total += metricSampleValue(t, p)
		}
	}
	return total
}
