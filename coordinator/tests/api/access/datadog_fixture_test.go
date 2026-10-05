package access_test

import (
	"log/slog"
	"net"
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
	client, err := datadog.NewClient(datadog.Config{StatsdAddr: collector.conn.LocalAddr().String(), FlushSecs: 60}, slog.New(slog.DiscardHandler))
	if err != nil {
		t.Fatal(err)
	}
	return client
}

func hasMetric(packets []string, substr string) bool {
	for _, p := range packets {
		if strings.Contains(p, substr) {
			return true
		}
	}
	return false
}
