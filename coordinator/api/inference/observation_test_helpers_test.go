package inference

import (
	"sort"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
)

const envProfiler = "EIGENINFERENCE_PROFILER"

// Expected serialized metric keys for cross-domain metric assertions. The
// metric registry's private key construction is tested in observation itself.
func metricKey(name string, labels []observation.MetricLabel) string {
	if len(labels) == 0 {
		return name
	}
	labels = append([]observation.MetricLabel(nil), labels...)
	sort.SliceStable(labels, func(i, j int) bool { return labels[i].Name < labels[j].Name })
	parts := make([]string, len(labels))
	for i, l := range labels {
		parts[i] = l.Name + "=" + l.Value
	}
	return name + "{" + strings.Join(parts, ",") + "}"
}
