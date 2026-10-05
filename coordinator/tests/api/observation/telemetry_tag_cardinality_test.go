package observation_test

import (
	"fmt"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api/observation"
	metriclabels "github.com/eigeninference/d-inference/coordinator/internal/observation/labels"
)

func TestTelemetryTagsCollapseRotatingRegistrationValues(t *testing.T) {
	versions := map[string]bool{}
	chips := map[string]bool{}
	for i := range 10000 {
		for _, version := range []string{fmt.Sprintf("0.8.%d", i), fmt.Sprintf("0.8.16-rc.%d", i), fmt.Sprintf("%d.1.1", i)} {
			versions[metriclabels.Version(version)] = true
		}
		chips[production.SanitizeChipFamilyTag(fmt.Sprintf("build%d", i))] = true
	}
	if len(versions) != 3 || !versions["0.8.x"] || !versions["prerelease"] || !versions["other_release"] {
		t.Fatalf("rotating semver values escaped fixed buckets: %v", versions)
	}
	if len(chips) != 1 || !chips["other"] {
		t.Fatalf("rotating chip labels escaped the fallback: %v", chips)
	}
}
