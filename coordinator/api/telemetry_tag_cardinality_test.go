package api

import (
	"fmt"
	"testing"
)

func TestTelemetryTagsCollapseRotatingRegistrationValues(t *testing.T) {
	versions := map[string]bool{}
	chips := map[string]bool{}
	for i := range 10000 {
		for _, version := range []string{fmt.Sprintf("0.8.%d", i), fmt.Sprintf("0.8.16-rc.%d", i), fmt.Sprintf("%d.1.1", i)} {
			versions[sanitizeVersionTag(version)] = true
		}
		chips[sanitizeChipFamilyTag(fmt.Sprintf("build%d", i))] = true
	}
	if len(versions) != 3 || !versions["0.8.x"] || !versions["prerelease"] || !versions["other_release"] {
		t.Fatalf("rotating semver values escaped fixed buckets: %v", versions)
	}
	if len(chips) != 1 || !chips["other"] {
		t.Fatalf("rotating chip labels escaped the fallback: %v", chips)
	}
}

func TestClientGoneChipTagsUseSameVocabularyAsMLX(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv := &Server{dd: dd}
	for _, chip := range []string{"build1", "build2", "M4 Pro", ""} {
		srv.emitClientGoneBucketed("m", 100, chip, phaseBeforeFirstToken, deadlineBucketUnknown)
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
