// Package metrics owns the process-local counters, histograms, computed
// gauges and their snapshots. Callers wire collection and HTTP endpoints; this
// package has no API server or exporter dependencies.
package metrics
