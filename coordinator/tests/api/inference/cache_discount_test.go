package inference_test

import (
	"strconv"
	"strings"
	"testing"

	cacheusage "github.com/eigeninference/d-inference/coordinator/internal/inference/cacheusage"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// billing.cache_read_discount_micro_usd reports only a discount the consumer
// actually received: a request that settled at its computed price above the
// per-request minimum. Under the minimum the bill is the minimum either way,
// and an overage clamp settles at a cap the cold price would have hit too.
func TestCacheReadDiscountMetricCountsOnlySettledDiscounts(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.observation.SetDatadog(dd)

	rates := payments.Rates{Input: 300_000, Output: 1_200_000, CacheRead: 30_000}
	for _, model := range []string{"disc-settled", "disc-minimum", "disc-clamped"} {
		cacheRead := rates.CacheRead
		if err := st.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: model, InputPrice: rates.Input, OutputPrice: rates.Output, CacheReadPrice: &cacheRead}); err != nil {
			t.Fatal(err)
		}
	}
	hit := cacheHitUsage()
	cold := rates.CostWithMinimum(payments.Usage{PromptTokens: hit.PromptTokens, CompletionTokens: hit.CompletionTokens})
	wantDiscount := payments.CacheReadDiscount(rates.CostWithMinimum, cacheusage.Billable(hit))
	if wantDiscount <= 0 {
		t.Fatalf("test setup: discount %d must be positive", wantDiscount)
	}

	// Settled at its computed price: the full discount counts.
	settleOnce(t, srv, ledger, "disc-prov-settled", "disc-settled", testConsumerID, cold, hit)

	// Cold and warm both under the 100 µUSD minimum: the bill is the minimum
	// either way, so no discount was given.
	tiny := protocol.UsageInfo{PromptTokens: 200, CompletionTokens: 10, CacheOutcome: "hit", CacheTier: "ssd", CachedTokens: 150, PrefillTokensSaved: 140, CacheStageMs: 1}
	if rates.Cost(cacheusage.Billable(tiny)) >= payments.MinimumCharge() || payments.CacheReadDiscount(rates.Cost, cacheusage.Billable(tiny)) == 0 {
		t.Fatal("test setup: tiny request must sit under the minimum with a per-token discount")
	}
	settleOnce(t, srv, ledger, "disc-prov-minimum", "disc-minimum", testConsumerID, payments.MinimumCharge(), tiny)

	// Reservation far below the cost: the overage clamp settles at 2× the
	// reservation, a cap the cold price hits as well.
	settleOnce(t, srv, ledger, "disc-prov-clamped", "disc-clamped", testConsumerID, 200, hit)

	_ = dd.Statsd.Flush()
	lines := findMetrics(collector.drain(), "billing.cache_read_discount_micro_usd")
	var settled []string
	for _, line := range lines {
		switch {
		case strings.Contains(line, "model:disc-settled"):
			settled = append(settled, line)
		case strings.Contains(line, "model:disc-minimum"), strings.Contains(line, "model:disc-clamped"):
			t.Errorf("discount metric emitted for a request that got no discount: %s", line)
		}
	}
	if len(settled) != 1 || !strings.Contains(settled[0], ":"+strconv.FormatInt(wantDiscount, 10)+"|c") {
		t.Fatalf("settled discount lines = %v, want one count of %d", settled, wantDiscount)
	}
}
