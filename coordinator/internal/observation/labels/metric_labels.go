package labels

import (
	"sort"
	"strings"
)

// MetricLabel is a single label (name, value) attached to a metric sample.
type MetricLabel struct {
	Name  string
	Value string
}

// metricKey serializes name + labels into a stable map key used for lookups.
// Labels are sorted so the order callers pass them in doesn't matter.
func Key(name string, labels []MetricLabel) string {
	if len(labels) == 0 {
		return name
	}
	sort.SliceStable(labels, func(i, j int) bool { return labels[i].Name < labels[j].Name })
	var b strings.Builder
	b.WriteString(name)
	b.WriteByte('{')
	for i, l := range labels {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(l.Name)
		b.WriteByte('=')
		b.WriteString(l.Value)
	}
	b.WriteByte('}')
	return b.String()
}
