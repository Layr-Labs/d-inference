package inference_test

import (
	"context"
	"encoding/base64"
	"fmt"
	"math"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/routeplan"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestCachePlanningArtifactReasonPrecedence(t *testing.T) {
	for _, tc := range []struct {
		name   string
		exists bool
		status promptcontract.ProvisionStatus
		want   routeplan.CachePlanningDecisionReason
	}{
		{"missing overrides supplied fields", false, promptcontract.ProvisionStatus{ArtifactReady: true, PromptContractID: "contract"}, routeplan.CachePlanningArtifactMissing},
		{"pending", true, promptcontract.ProvisionStatus{}, routeplan.CachePlanningArtifactPending},
		{"failed", true, promptcontract.ProvisionStatus{LastError: "private-error-and-path"}, routeplan.CachePlanningArtifactFailed},
		{"nonready before empty ID", true, promptcontract.ProvisionStatus{LastError: "private-error"}, routeplan.CachePlanningArtifactFailed},
		{"ready empty ID", true, promptcontract.ProvisionStatus{ArtifactReady: true, LastError: "stale-error"}, routeplan.CachePlanningArtifactInvalid},
		{"ready preserves existing contract", true, promptcontract.ProvisionStatus{ArtifactReady: true, PromptContractID: "contract", LastError: "stale-error"}, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := routeplan.CachePlanningArtifactReason(tc.status, tc.exists); got != tc.want {
				t.Fatalf("reason=%q want=%q", got, tc.want)
			}
		})
	}
}

func TestCachePlanningRegistryReasonVocabulary(t *testing.T) {
	for _, tc := range []struct {
		outcome registry.CachePlanOutcome
		want    string
	}{
		{registry.CachePlanOff, "off"}, {registry.CachePlanIneligible, "ineligible"},
		{registry.CachePlanSampledOut, "sampled_out"}, {registry.CachePlanThrottled, "throttled"},
		{registry.CachePlanColdOnly, "cold_only"}, {registry.CachePlanSidecarError, "sidecar_error"},
		{registry.CachePlanNoBoundaries, "no_boundaries"}, {registry.CachePlanInvalid, "invalid_plan"},
		{registry.CachePlanPlanned, "planned"}, {"", "unknown_outcome"},
		{"private-unrecognized-result", "unknown_outcome"},
	} {
		if got := routeplan.BoundedCachePlanningReason(routeplan.CachePlanningResultReason(tc.outcome)); got != tc.want {
			t.Errorf("outcome=%q reason=%q want=%q", tc.outcome, got, tc.want)
		}
	}
	if got := routeplan.BoundedCachePlanningReason("private-unrecognized-reason"); got != "unknown_outcome" {
		t.Fatalf("unchecked reason escaped the bounded vocabulary: %q", got)
	}
}

func TestCachePlanningDecisionMetricsPopulation(t *testing.T) {
	reasons := []routeplan.CachePlanningDecisionReason{
		routeplan.CachePlanningLoweringUnsupported, routeplan.CachePlanningDependenciesUnavailable,
		routeplan.CachePlanningArtifactMissing, routeplan.CachePlanningArtifactPending, routeplan.CachePlanningArtifactFailed,
		routeplan.CachePlanningArtifactInvalid, routeplan.CachePlanningPreloadNotReady, routeplan.CachePlanningOff,
		routeplan.CachePlanningIneligible, routeplan.CachePlanningSampledOut, routeplan.CachePlanningThrottled,
		routeplan.CachePlanningColdOnly, routeplan.CachePlanningSidecarError, routeplan.CachePlanningNoBoundaries,
		routeplan.CachePlanningInvalidPlan, routeplan.CachePlanningPlanned, routeplan.CachePlanningUnknownOutcome,
	}
	s := newCachePlanningOwner(t)
	seen := map[string]bool{}
	for _, reason := range reasons {
		value := routeplan.BoundedCachePlanningReason(reason)
		if seen[value] {
			t.Fatalf("duplicate reason %q", value)
		}
		seen[value] = true
		s.NewCachePlanner().EmitDecision("unknown", reason, 1250*time.Microsecond)
	}
	if len(seen) != 17 {
		t.Fatalf("decision vocabulary size=%d", len(seen))
	}
	snapshot := s.observation.Metrics().Snapshot()
	for reason := range seen {
		count := "exact_cache_planning_decision_total{reason=" + reason + "}"
		latency := "exact_cache_planning_decision_latency_ms{reason=" + reason + "}"
		model := "{model=unknown,reason=" + reason + "}"
		if snapshot.Counters[count] != 1 || snapshot.Histograms[latency].Count != 1 || snapshot.Histograms[latency].Sum != 1.25 {
			t.Errorf("decision count/latency mismatch for %s", reason)
		}
		if snapshot.Counters["cache_model_planning_decision_total"+model] != 1 ||
			snapshot.Counters["cache_model_planning_decision_latency_us_total"+model] != 1250 ||
			snapshot.Counters["cache_model_planning_decision_latency_samples_total"+model] != 1 ||
			snapshot.Histograms["cache_model_planning_decision_latency_ms"+model].Count != 1 {
			t.Errorf("catalog model mirror mismatch for %s", reason)
		}
	}
	for name := range snapshot.Counters {
		if strings.HasPrefix(name, "exact_cache_plan_total") {
			t.Fatal("new decision emitter changed legacy planning population")
		}
	}
}

func TestCachePlanningDecisionElapsedBounds(t *testing.T) {
	for _, elapsed := range []time.Duration{-time.Second, 0, time.Duration(math.MaxInt64)} {
		s := newCachePlanningOwner(t)
		s.NewCachePlanner().EmitDecision("unknown", routeplan.CachePlanningOff, elapsed)
		histogram := s.observation.Metrics().Snapshot().Histograms["exact_cache_planning_decision_latency_ms{reason=off}"]
		if histogram.Count != 1 || histogram.Sum < 0 || math.IsNaN(histogram.Sum) || math.IsInf(histogram.Sum, 0) {
			t.Fatalf("invalid elapsed sample: %+v", histogram)
		}
	}
}

func TestCachePlanningLoweringRefusalPrecedesMissingDependencies(t *testing.T) {
	s := newCachePlanningOwner(t)
	plan := s.NewCachePlanner().PlanResult(context.Background(), routeplan.CachePlanningInput{
		Account: "private-account", Model: "private-alias", Body: []byte(`{"private":"body"}`),
		HasMedia: true, LoweringFailed: true,
	}).Plan
	if plan.CacheScope != "" || len(plan.Boundaries) != 0 {
		t.Fatal("unsupported lowering participated in cache routing")
	}
	snapshot := s.observation.Metrics().Snapshot()
	if snapshot.Counters["exact_cache_planning_decision_total{reason=lowering_unsupported}"] != 1 ||
		snapshot.Counters["exact_cache_planning_decision_total{reason=dependencies_unavailable}"] != 0 {
		t.Fatal("lowering/prerequisite precedence changed")
	}
	encoded := fmt.Sprintf("%v%v", snapshot.Counters, snapshot.Histograms)
	for _, private := range []string{"private-account", "private-alias", "private\":\"body"} {
		if strings.Contains(encoded, private) {
			t.Fatal("private input reached decision metrics")
		}
	}
}

func TestCachePlanningModelLabelUsesCatalogNotCallerAlias(t *testing.T) {
	s, _, _ := billingTestServer(t)
	t.Cleanup(s.Close)
	s.registry.SetModelCatalog([]registry.CatalogEntry{{ID: "fixture-model"}})
	for _, model := range []string{"fixture-model", "unregistered-private-alias"} {
		s.NewCachePlanner().PlanResult(context.Background(), routeplan.CachePlanningInput{Account: "private-account", Model: model})
	}
	snapshot := s.observation.Metrics().Snapshot()
	for _, model := range []string{"fixture-model", "unknown"} {
		name := "cache_model_planning_decision_total{model=" + model + ",reason=dependencies_unavailable}"
		if snapshot.Counters[name] != 1 {
			t.Errorf("missing bounded model sample %s", name)
		}
	}
	if strings.Contains(fmt.Sprint(snapshot.Counters, snapshot.Histograms), "unregistered-private-alias") {
		t.Fatal("unregistered caller alias leaked")
	}
}

func TestCachePlanningAbsoluteClockFormulaAndContextValues(t *testing.T) {
	type contextKey struct{}
	parent := context.WithValue(context.Background(), contextKey{}, "fixture-value")
	received := time.Now().Add(-time.Second)
	budget := 3 * time.Second
	child, release := firstcontent.FirstTokenWriteContext(parent, received, budget)
	deadline, present := child.Deadline()
	if !present || !deadline.Equal(received.Add(budget)) || child.Value(contextKey{}) != "fixture-value" {
		t.Fatal("original absolute deadline or context value changed")
	}
	release()
	if parent.Err() != nil || child.Err() != context.Canceled {
		t.Fatal("child cleanup did not remain child-local")
	}
	for _, tc := range []struct {
		received time.Time
		budget   time.Duration
	}{
		{time.Time{}, time.Second},
		{received, 0},
		{received, -time.Second},
	} {
		passthrough, release := firstcontent.FirstTokenWriteContext(parent, tc.received, tc.budget)
		if passthrough != parent {
			t.Fatal("zero/nonpositive clock created a new context")
		}
		if _, present := passthrough.Deadline(); present {
			t.Fatal("zero/nonpositive clock acquired an artificial deadline")
		}
		release()
		if parent.Err() != nil {
			t.Fatal("passthrough release was not a no-op")
		}
	}
	earlier := time.Now().Add(time.Second)
	parent, cancelParent := context.WithDeadline(parent, earlier)
	defer cancelParent()
	child, release = firstcontent.FirstTokenWriteContext(parent, time.Now(), time.Hour)
	defer release()
	deadline, present = child.Deadline()
	if !present || !deadline.Equal(earlier) || child.Value(contextKey{}) != "fixture-value" {
		t.Fatal("earlier parent deadline/value did not win")
	}
}

func TestCachePlanningRegistryEligibilityAndActivationPreserved(t *testing.T) {
	s := newCachePlanningOwner(t)
	f := newCachePlanningUDSFixture(t, s.Owner, s.registry)
	for _, tc := range []struct {
		name, reason string
		change       func(*routeplan.CachePlanningInput, *registry.CacheRoutingConfig)
		sampled      bool
	}{
		{"media before sampling", "ineligible", func(in *routeplan.CachePlanningInput, cfg *registry.CacheRoutingConfig) {
			in.HasMedia, cfg.ActivationPct = true, 1
		}, false},
		{"missing account before sampling", "ineligible", func(in *routeplan.CachePlanningInput, cfg *registry.CacheRoutingConfig) {
			in.Account, cfg.ActivationPct = "", 1
		}, false},
		{"empty body before sampling", "ineligible", func(in *routeplan.CachePlanningInput, cfg *registry.CacheRoutingConfig) {
			in.Body, cfg.ActivationPct = nil, 1
		}, false},
		{"artifact refusal before sampling", "ineligible", func(_ *routeplan.CachePlanningInput, cfg *registry.CacheRoutingConfig) {
			cfg.AllowedArtifacts, cfg.ActivationPct = []registry.CacheRoutingArtifact{}, 1
		}, false},
		{"sampled out", "sampled_out", func(_ *routeplan.CachePlanningInput, cfg *registry.CacheRoutingConfig) {
			// Fixed fixture key/account/model/body select the same cohort on
			// every run. Use the supported 1% setting, not invalid zero.
			cfg.ActivationPct = 1
		}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			input := f.input()
			cfg := registry.CacheRoutingConfig{Mode: registry.CacheRoutingOn, ActivationPct: 100,
				MasterKey: base64.RawURLEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef"))}
			tc.change(&input, &cfg)
			if err := s.registry.ConfigureCacheRouting(cfg); err != nil {
				t.Fatal(err)
			}
			before, requests := s.observation.Metrics().Snapshot(), f.state(t).Plans
			if plan := s.NewCachePlanner().PlanResult(context.Background(), input).Plan; plan.CacheScope != "" {
				t.Fatal("ineligible or sampled-out request retained participation")
			}
			after := s.observation.Metrics().Snapshot()
			decision := "exact_cache_planning_decision_total{reason=" + tc.reason + "}"
			legacy := "exact_cache_plan_total{outcome=" + tc.reason + "}"
			if after.Counters[decision]-before.Counters[decision] != 1 || after.Counters[legacy]-before.Counters[legacy] != 1 {
				t.Fatal("API decision and unchanged Registry outcome do not agree")
			}
			if f.state(t).Plans != requests || after.Histograms["exact_cache_plan_latency_ms{outcome="+tc.reason+"}"].Count != 0 {
				t.Fatal("pre-client refusal submitted sidecar work or gained sidecar timing")
			}
			activation := s.registry.CacheRoutingActivationStatus()
			if tc.sampled {
				if activation.Evaluated != 1 || activation.SampledOut != 1 || activation.Admitted != 0 {
					t.Fatalf("sampling accounting changed: %+v", activation)
				}
			} else if activation.Evaluated != 0 {
				t.Fatalf("eligibility refusal reached activation: %+v", activation)
			}
		})
	}
	// A sub-one-QPS bucket has one initial token. Its refill interval is much
	// longer than the bounded fixture, so no wall-clock boundary can grant a
	// second plan between these consecutive calls.
	cfg := registry.CacheRoutingConfig{Mode: registry.CacheRoutingOn, ActivationPct: 100, MaxPlanQPS: .001,
		MasterKey: base64.RawURLEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef"))}
	if err := s.registry.ConfigureCacheRouting(cfg); err != nil {
		t.Fatal(err)
	}
	requests := f.state(t).Plans
	if s.NewCachePlanner().PlanResult(context.Background(), f.input()).Plan.CacheScope == "" {
		t.Fatal("initial QPS token did not allow ordinary planning")
	}
	if s.NewCachePlanner().PlanResult(context.Background(), f.input()).Plan.CacheScope != "" {
		t.Fatal("exhausted QPS budget retained participation")
	}
	activation := s.registry.CacheRoutingActivationStatus()
	if f.state(t).Plans != requests+1 || activation.Evaluated != 2 || activation.Admitted != 1 || activation.RateLimited != 1 || activation.Planned != 1 {
		t.Fatalf("QPS accounting or actual transport count changed: %+v", activation)
	}
	snapshot := s.observation.Metrics().Snapshot()
	if snapshot.Counters["exact_cache_planning_decision_total{reason=throttled}"] != 1 ||
		snapshot.Counters["exact_cache_plan_total{outcome=throttled}"] != 1 ||
		snapshot.Histograms["exact_cache_plan_latency_ms{outcome=throttled}"].Count != 0 {
		t.Fatal("QPS refusal changed API/legacy metric populations")
	}
}
