package inference_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
)

func counterKey(name string, labels ...observation.MetricLabel) string {
	return metricKey(name, labels)
}

// waitForCounter polls the in-process metrics snapshot until pred holds or
// the deadline passes; returns the final snapshot.
func waitForCounters(t *testing.T, srv *serverFixture, timeout time.Duration, pred func(observation.MetricsSnapshot) bool) observation.MetricsSnapshot {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		snap := srv.observation.Metrics().Snapshot()
		if pred(snap) || time.Now().After(deadline) {
			return snap
		}
		time.Sleep(20 * time.Millisecond)
	}
}
