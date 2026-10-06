package billing_test

import (
	"net/http"
	"net/http/httptest"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/billing"
)

func TestPayoutEvidenceUsesPayoutFilterAndIgnoresUnprovenSources(t *testing.T) {
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("payout") != "po_test" || r.Header.Get("Stripe-Account") != "acct_test" || r.URL.Query().Get("expand[]") != "data.source" {
			t.Error("evidence request not scoped to payout and account")
		}
		_, _ = w.Write([]byte(`{"data":[{"id":"txn_1","amount":500,"source":{"object":"charge","source_transfer":"tr_yes","amount_refunded":0}},{"id":"txn_2","amount":500,"source":{"object":"charge","source_transfer":"tr_refunded","amount_refunded":100}},{"id":"txn_3","amount":500,"source":"py_unknown"}],"has_more":false}`))
	}))
	defer remote.Close()
	restore := production.SetStripeAPIBaseForTest(remote.URL)
	defer production.SetStripeAPIBaseForTest(restore)
	c := production.NewStripeConnect("rk_test", "", "US", false, silentLogger())
	got, err := c.PayoutTransfers("acct_test", "po_test")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || !got["tr_yes"] {
		t.Fatalf("unproven payout attribution: %v", got)
	}
}
