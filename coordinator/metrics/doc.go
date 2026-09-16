// Package metrics is the coordinator's metric catalog: every metric the process
// emits is declared here once, with its name, type, help text and label keys,
// and call sites reach it through a typed method rather than a string literal.
//
// # Why a catalog
//
// Before this package a metric was a string literal at the call site and its
// tags were a []string built by hand. 270 names appeared across 400 call sites,
// the same name was spelled at up to a dozen of them, nothing checked that two
// sites tagged one series the same way, and the only way to find out what the
// coordinator emits was to grep for `s.ddIncr(`. Declaring the metric separates
// the decision (what this series is, how it is tagged, what it means) from the
// act of recording a sample, so the decision is reviewable in one place and the
// call site is a method call the compiler checks.
//
// # Push, not pull
//
// The shape is borrowed from eigenda's metrics declarations, but the transport
// is not: eigenda declares Prometheus collectors and a scraper reads them, and
// here a declared collector writes DogStatsD datagrams to the local agent
// (../datadog). Three consequences follow from that, and they are the reason
// this package cannot be read as "our promauto":
//
//   - A gauge is not remembered. A Prometheus GaugeVec holds its last Set value
//     until something changes it, so a scrape always finds a value; a pushed
//     gauge exists only in the flush window it was sent in. Anything that must
//     be continuously readable has to be re-emitted on a loop
//     (api.Server.StartDDGaugeLoop), and that is deliberate, not a gap.
//   - A counter is a delta, not a total. DogStatsD counters are per-flush
//     increments that the intake sums, so a provider-side cumulative counter has
//     to be differenced before it is recorded, never submitted raw.
//   - Latency is a distribution, not buckets. There is no histogram_quantile()
//     at the other end: values are forwarded raw and Datadog computes the
//     percentile over the queried range, which is why Distribution is the type
//     for a timing and why bucket boundaries appear nowhere in this package.
//
// # Two sinks, one declaration
//
// A metric can also be mirrored into the in-process registry that backs
// GET /v1/admin/metrics. That mirror predates this package and its names are
// not the Datadog names (`cache_model_usage_total` against
// `routing.cache_model.usage`), which is exactly why both belong on one
// declaration: the pair is visible, and a metric cannot silently acquire or
// lose its mirror. Where a declaration names no mirror, there is none.
//
// # Adding a metric
//
// Declare it in the catalog file for its subsystem, give it a help string that
// says what a non-author would need to know, and add the typed recording method
// next to it. Two rules the tests enforce: a name is declared exactly once, and
// a name that already exists in Datadog keeps its type — the intake rejects a
// submission that changes it and every stored query on it breaks (see
// lockedGauge).
package metrics
