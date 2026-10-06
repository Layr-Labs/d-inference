package inference_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
)

func TestClientGoneChipTagsUseSameVocabularyAsMLX(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv := &serverFixture{observation: observation.New(observation.Dependencies{})}
	srv.observation.SetDatadog(dd)
	for _, chip := range []string{"build1", "build2", "M4 Pro", ""} {
		srv.NewMetrics().ClientGoneBucketed("m", 100, chip, phaseBeforeFirstToken, deadlineBucketUnknown)
	}
	_ = dd.Statsd.Flush()
	packets := collector.drain()
	for _, tag := range []string{"chip_family:other", "chip_family:M4_Pro", "chip_family:unknown"} {
		requireMetricWithTags(t, packets, "routing.client_gone", tag)
	}
	for _, line := range findMetrics(packets, "routing.client_gone") {
		if containsTag(line, "chip_family:build1") || containsTag(line, "chip_family:build2") {
			t.Fatalf("provider-controlled chip label escaped: %s", line)
		}
	}
}
