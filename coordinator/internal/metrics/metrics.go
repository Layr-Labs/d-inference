// Package metrics defines the Prometheus instruments exposed by the
// coordinator at /metrics. Each metric is a package-level variable so
// call sites stay terse (`metrics.HTTPRequests.WithLabelValues(...).Inc()`).
//
// Naming follows the Prometheus convention: snake_case, units in the
// suffix (`_seconds`, `_bytes`, `_total`). Histograms use base-2 buckets
// for latency since most of our HTTP calls are sub-second but inference
// can take 30+ seconds.
package metrics

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

var (
	// HTTPRequests counts every HTTP request the coordinator handles.
	// Cardinality: path × method × status. We use the Go-1.22 method+path
	// pattern from the mux as the path label so cardinality stays bounded
	// (no per-user-input variation).
	HTTPRequests = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "eigeninference_http_requests_total",
		Help: "Total HTTP requests handled, partitioned by route, method, and status.",
	}, []string{"route", "method", "status"})

	// HTTPRequestDuration tracks request latency. Buckets cover the full
	// range from cheap reads (1ms) to long inferences (60s) at base-2.
	HTTPRequestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "eigeninference_http_request_duration_seconds",
		Help:    "HTTP request handler latency in seconds.",
		Buckets: []float64{0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 2, 5, 10, 30, 60, 120},
	}, []string{"route", "method"})

	// ProvidersConnected reflects the size of the registry. Updated by
	// the registry on connect/disconnect.
	ProvidersConnected = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "eigeninference_providers_connected",
		Help: "Number of providers currently connected via WebSocket.",
	})

	// ProvidersIdle is the subset of connected providers eligible for
	// new request dispatch (status=online, recent challenge, no pending).
	ProvidersIdle = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "eigeninference_providers_idle",
		Help: "Number of connected providers eligible to accept a new request.",
	})

	// QueueDepth is the depth of the request queue (requests waiting for
	// a provider to free up).
	QueueDepth = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "eigeninference_request_queue_depth",
		Help: "Requests currently waiting for an available provider.",
	})

	// InferenceCompleted counts successful inference completions, labeled
	// by model. Use rate() at query time for throughput.
	InferenceCompleted = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "eigeninference_inference_completions_total",
		Help: "Total successful inference completions, partitioned by model.",
	}, []string{"model"})

	// InferenceCompletionTokens counts the total completion tokens
	// generated across the fleet, labeled by model. Useful to spot a
	// model whose effective token cost is climbing.
	InferenceCompletionTokens = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "eigeninference_inference_completion_tokens_total",
		Help: "Total completion tokens generated, partitioned by model.",
	}, []string{"model"})

	// RateLimitRejections counts how often the per-account limiter
	// returned 429, labeled by which limiter (consumer or financial).
	RateLimitRejections = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "eigeninference_rate_limit_rejections_total",
		Help: "Requests rejected by per-account rate limiter, by tier.",
	}, []string{"tier"})

	// AttestationChallenges counts attestation challenges emitted vs
	// passed/failed/missing-status-sig.
	AttestationChallenges = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "eigeninference_attestation_challenges_total",
		Help: "Attestation challenges by outcome.",
	}, []string{"outcome"}) // outcome: sent, passed, failed, status_sig_missing

	// PanicsRecovered counts goroutine panics caught by saferun.Recover.
	// A non-zero value is a strong incident signal.
	PanicsRecovered = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "eigeninference_goroutine_panics_recovered_total",
		Help: "Panics caught by saferun.Recover, by goroutine name.",
	}, []string{"goroutine"})

	// RoutingDecisions counts every routing attempt by outcome. Read with
	// rate() to spot regressions: a sudden surge in `over_capacity` means
	// the fleet is undersized for a hot model; `no_provider` means the
	// model has zero eligible providers (catalog/trust drift).
	RoutingDecisions = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "eigeninference_routing_decisions_total",
		Help: "Routing attempts by outcome.",
	}, []string{"model", "outcome"}) // outcome: selected, queued, no_provider, over_capacity

	// ProviderSelected counts how often each provider wins a routing
	// decision. Distribution skew here is the primary signal for whether
	// the cost function is balancing load — a single provider with >>50%
	// of selections while others sit idle indicates the scorer is biased.
	// Cardinality is bounded by fleet size × catalog size (small).
	ProviderSelected = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "eigeninference_provider_selected_total",
		Help: "Routing wins per provider, partitioned by model.",
	}, []string{"provider_id", "model"})

	// RoutingCostMs is the winning candidate's cost (ms) at selection
	// time. Buckets cover idle (sub-second) up to overloaded (60s+).
	// Use to track whether the median routing cost climbs as load grows
	// — a healthy fleet should keep p50 cost roughly flat.
	RoutingCostMs = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "eigeninference_routing_cost_milliseconds",
		Help:    "Cost (in ms) of the winning provider at selection time.",
		Buckets: []float64{100, 250, 500, 1000, 2500, 5000, 10000, 20000, 40000, 60000, 120000},
	}, []string{"model"})

	// EffectiveDecodeTPS is the load-adjusted decode tokens-per-second
	// the scheduler attributed to a provider at the time of selection.
	// Only emitted when the load-scaling factor is in effect; otherwise
	// matches the static benchmarked value.
	EffectiveDecodeTPS = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "eigeninference_provider_effective_decode_tps",
		Help: "Load-adjusted decode tokens-per-second used by the scheduler.",
	}, []string{"provider_id"})
)
