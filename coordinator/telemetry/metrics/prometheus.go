package metrics

import (
	"fmt"
	"strings"
)

// RenderProm returns the snapshot in Prometheus exposition format.
func (s Snapshot) RenderProm() string {
	var b strings.Builder

	// Counters — the metric key already has the Prometheus-style label suffix.
	// Convert internal "name{a=1,b=2}" into Prom "name{a=\"1\",b=\"2\"}".
	writtenTypes := map[string]struct{}{}
	for key, v := range s.Counters {
		name, labels := splitPromKey(key)
		if _, ok := writtenTypes[name]; !ok {
			fmt.Fprintf(&b, "# TYPE %s counter\n", name)
			writtenTypes[name] = struct{}{}
		}
		fmt.Fprintf(&b, "%s%s %d\n", name, labels, v)
	}
	for key, g := range s.Gauges {
		name, labels := splitPromKey(key)
		if _, ok := writtenTypes[name]; !ok {
			fmt.Fprintf(&b, "# TYPE %s gauge\n", name)
			writtenTypes[name] = struct{}{}
		}
		fmt.Fprintf(&b, "%s%s %g\n", name, labels, g)
	}
	for key, h := range s.Histograms {
		name, labels := splitPromKey(key)
		if _, ok := writtenTypes[name]; !ok {
			fmt.Fprintf(&b, "# TYPE %s histogram\n", name)
			writtenTypes[name] = struct{}{}
		}
		// Each bucket gets a synthetic label le="<upper>" appended to existing labels.
		for i, bucket := range h.Buckets {
			fmt.Fprintf(&b, "%s_bucket%s %d\n", name, mergeLabels(labels, "le", fmt.Sprintf("%g", bucket)), h.Counts[i])
		}
		fmt.Fprintf(&b, "%s_bucket%s %d\n", name, mergeLabels(labels, "le", "+Inf"), h.Counts[len(h.Counts)-1])
		fmt.Fprintf(&b, "%s_sum%s %g\n", name, labels, h.Sum)
		fmt.Fprintf(&b, "%s_count%s %d\n", name, labels, h.Count)
	}
	return b.String()
}

// splitPromKey separates the metric name from the Prom-style label block.
// Input:  "foo{a=1,b=2}"
// Output: name="foo", labels=`{a="1",b="2"}`.
func splitPromKey(key string) (string, string) {
	i := strings.IndexByte(key, '{')
	if i < 0 {
		return key, ""
	}
	name := key[:i]
	inner := strings.TrimSuffix(strings.TrimPrefix(key[i:], "{"), "}")
	if inner == "" {
		return name, ""
	}
	pairs := strings.Split(inner, ",")
	out := make([]string, 0, len(pairs))
	for _, p := range pairs {
		if eq := strings.IndexByte(p, '='); eq > 0 {
			k := p[:eq]
			v := p[eq+1:]
			out = append(out, fmt.Sprintf("%s=%q", k, v))
		}
	}
	return name, "{" + strings.Join(out, ",") + "}"
}

// mergeLabels appends one more label (k=v) to an existing "{...}" block.
func mergeLabels(existing, key, val string) string {
	quoted := fmt.Sprintf("%s=%q", key, val)
	if existing == "" {
		return "{" + quoted + "}"
	}
	// existing is already "{...}" — splice the new label in.
	return existing[:len(existing)-1] + "," + quoted + "}"
}
