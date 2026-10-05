package inference_test

import (
	"strconv"
	"strings"
	"testing"
)

// metricSampleValue parses the numeric value out of a DogStatsD packet
// ("d_inference.<name>:<value>|<type>|#tags"). The client aggregates identical
// counter samples inside a flush window into one packet whose value is the
// sum, so tests must add values rather than count packets.
func metricSampleValue(t *testing.T, packet string) float64 {
	t.Helper()
	colon := strings.Index(packet, ":")
	pipe := strings.Index(packet, "|")
	if colon < 0 || pipe < 0 || pipe <= colon {
		t.Fatalf("unparseable DogStatsD packet %q", packet)
	}
	v, err := strconv.ParseFloat(packet[colon+1:pipe], 64)
	if err != nil {
		t.Fatalf("packet %q: bad value: %v", packet, err)
	}
	return v
}

// sumMetric adds the values of every packet that carries the metric name and
// ALL of the given tag substrings.
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
