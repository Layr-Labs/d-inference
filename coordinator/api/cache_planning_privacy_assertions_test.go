package api

import (
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type privacyPlanningMark struct {
	proxy      int
	rust       promptcontract.SidecarStatus
	counters   map[string]int64
	dispatches int
	balance    int64
	usage      int
}

func (f *privacyPlanningFixture) mark(t *testing.T, account string) privacyPlanningMark {
	t.Helper()
	m := privacyPlanningMark{proxy: f.proxy.count(), rust: cachePlanningRealMetrics(t, f.ctx, f.planning),
		counters: f.server.metrics.Snapshot().Counters, balance: f.store.GetBalance(account),
		usage: len(f.store.UsageByConsumer(account))}
	for _, provider := range f.providers {
		m.dispatches += provider.dispatchCount()
	}
	return m
}

func (f *privacyPlanningFixture) assertPlannedOnce(t *testing.T, before privacyPlanningMark) privacyPlanObservation {
	t.Helper()
	observations := f.proxy.since(t, before.proxy)
	if len(observations) != 1 {
		t.Fatalf("real planning calls=%d want1", len(observations))
	}
	observation := observations[0]
	if observation.Contract != f.planning.contract || observation.Scope == "" || observation.Endpoint != "chat_completions" {
		t.Fatal("planner did not receive the exact contract and authenticated scope")
	}
	assertPrivacyPlanningBody(t, observation.Body)
	after := cachePlanningRealMetrics(t, f.ctx, f.planning)
	if after.Metrics.Plans.Started != before.rust.Metrics.Plans.Started+1 ||
		after.Metrics.Plans.Succeeded != before.rust.Metrics.Plans.Succeeded+1 ||
		after.Metrics.Plans.Failed != before.rust.Metrics.Plans.Failed || after.PlanningPermitsAvailable != 1 {
		t.Fatal("observed forwarded request did not complete one actual Rust plan")
	}
	counters := f.server.metrics.Snapshot().Counters
	var decisions, legacy int64
	for name, value := range counters {
		if strings.HasPrefix(name, "exact_cache_planning_decision_total{") {
			decisions += value - before.counters[name]
		}
		if strings.HasPrefix(name, "exact_cache_plan_total{") {
			legacy += value - before.counters[name]
		}
	}
	if decisions != 1 || legacy != 1 ||
		counters["exact_cache_planning_decision_total{reason=planned}"]-before.counters["exact_cache_planning_decision_total{reason=planned}"] != 1 {
		t.Fatal("logical planning/legacy decision population changed")
	}
	return observation
}

func (f *privacyPlanningFixture) assertSuccess(t *testing.T, before privacyPlanningMark, account, endpoint string,
	stream bool, result privacyPlanningHTTPResult, attempts int, cached bool) []privacyPlanningDispatch {
	t.Helper()
	if result.err != nil || result.status != http.StatusOK || cachePlanningResponseText(endpoint, stream, string(result.body)) != privacyPlanningMarker {
		t.Fatalf("ordinary inference failed: status=%d error=%v body=%s", result.status, result.err, result.body)
	}
	if err := cachePlanningResponseTerminalError(endpoint, stream, string(result.body)); err != nil {
		t.Fatal(err)
	}
	if err := privacyConsumerResponseError(endpoint, stream, result.body); err != nil {
		t.Fatal(err)
	}
	plan := f.assertPlannedOnce(t, before)
	var observed []privacyPlanningDispatch
	seen := make(map[string]bool)
	for index := 0; index < attempts; index++ {
		select {
		case record := <-f.records:
			if record.frame.RequestID == "" || seen[record.frame.RequestID] || record.frame.EncryptedBody == nil ||
				record.frame.EncryptedBody.Ciphertext == "" || !reflect.DeepEqual(record.frame.Body, protocol.InferenceRequestBody{}) {
				t.Fatal("dispatch identity/encrypted-only envelope changed")
			}
			seen[record.frame.RequestID] = true
			assertPrivacyPlanningBody(t, record.body)
			if !record.telemetry || record.participates != cached || record.deadline.IsZero() || record.budget <= 0 ||
				record.frame.FirstContentBudgetMS <= 0 || record.frame.FirstContentBudgetMS > record.budget {
				t.Fatal("ordinary telemetry, cache participation or original writer budget changed")
			}
			if cached {
				if record.frame.PrefixCacheProtocol != 2 || record.frame.CacheReceiptNonce == "" ||
					record.frame.CacheScope != plan.Scope || record.frame.CacheReceiptBoundaryMode != protocol.PrefixCacheReadyBoundaryCheckpoint {
					t.Fatal("positive control lacks matching real-plan cache metadata")
				}
			} else if record.frame.PrefixCacheProtocol != 0 || record.frame.CacheReceiptNonce != "" ||
				record.frame.CacheScope != "" || record.frame.CacheReceiptBoundaryMode != "" {
				t.Fatal("byte-refused dispatch leaked cache metadata")
			}
			observed = append(observed, record)
		case <-time.After(time.Second):
			t.Fatal("expected encrypted attempt was not observed")
		}
	}
	select {
	case <-f.records:
		t.Fatal("unexpected extra provider attempt")
	default:
	}
	dispatches := 0
	for _, provider := range f.providers {
		dispatches += provider.dispatchCount()
		// The shared fake provider also retains decrypted bodies. Drain exactly
		// this request's copies; it must not accumulate an unrelated replay.
		for {
			select {
			case <-provider.bodies:
			default:
				goto drained
			}
		}
	drained:
	}
	if dispatches-before.dispatches != attempts {
		t.Fatal("provider dispatch count differs from the observed request")
	}
	orEventually(t, func() bool {
		f.server.serviceReservations.mu.Lock()
		holds := f.server.serviceReservations.outstanding[account]
		f.server.serviceReservations.mu.Unlock()
		return holds == 0 && f.store.GetBalance(account) == before.balance-orCost &&
			len(f.store.UsageByConsumer(account)) == before.usage+1
	}, "joint request billing and holds did not settle once")
	return observed
}
