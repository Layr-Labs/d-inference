package observation

import (
	"github.com/eigeninference/d-inference/coordinator/internal/observation/cachefunnel"
	metriclabels "github.com/eigeninference/d-inference/coordinator/internal/observation/labels"
)

// ObserveCacheFunnelRecord is the reuse funnel's record sink. It adds one
// closed request's observed token counts to the in-process registry served by
// the admin-authenticated GET /v1/admin/metrics. They stay off the public
// cache status because two snapshots around one closing request would differ
// by that request's exact counts, and they are not forwarded to Datadog.
// A quantity the coordinator did not observe adds nothing; the public status
// counts those requests as unknown.
func (s *Owner) ObserveCacheFunnelRecord(record cachefunnel.Record) {
	metrics := s.Metrics()
	if metrics == nil {
		return
	}
	reason := metriclabels.MetricLabel{Name: "reason", Value: record.Reason.String()}
	// The two provider-reported reuse quantities carry the hit's tier, so
	// memory and SSD reuse can be summed apart; "none" is every non-hit.
	tier := metriclabels.MetricLabel{Name: "tier", Value: record.HitTier.String()}
	addObservedTokens(metrics, "exact_cache_funnel_prompt_tokens_total", record.PromptTokens, reason)
	addObservedTokens(metrics, "exact_cache_funnel_repeated_prefix_tokens_total", record.RepeatedPrefixTokens, reason)
	addObservedTokens(metrics, "exact_cache_funnel_predicted_tokens_total", record.PredictedTokens, reason)
	addObservedTokens(metrics, "exact_cache_funnel_reused_tokens_total", record.ReusedTokens, reason, tier)
	addObservedTokens(metrics, "exact_cache_funnel_prefill_saved_tokens_total", record.PrefillSavedTokens, reason, tier)
	addObservedTokens(metrics, "exact_cache_funnel_provider_prompt_tokens_total", record.ProviderPromptTokens, reason)
}

// ObserveLateCacheFunnelCompletion adds the reuse a late completion reported
// to the same admin-only registry, by tier. These are the tokens the
// per-completion usage counters hold and no funnel record does.
func (s *Owner) ObserveLateCacheFunnelCompletion(late cachefunnel.LateCompletion) {
	metrics := s.Metrics()
	if metrics == nil {
		return
	}
	tier := metriclabels.MetricLabel{Name: "tier", Value: late.HitTier.String()}
	addObservedTokens(metrics, "exact_cache_funnel_late_reused_tokens_total", late.ReusedTokens, tier)
	addObservedTokens(metrics, "exact_cache_funnel_late_prefill_saved_tokens_total", late.PrefillSavedTokens, tier)
}

func addObservedTokens(metrics *Metrics, name string, tokens cachefunnel.Tokens, labels ...metriclabels.MetricLabel) {
	if tokens.Known {
		metrics.AddCounter(name, int64(tokens.Count), labels...)
	}
}
