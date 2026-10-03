package billing_test

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"nhooyr.io/websocket"
)

// Exercise pricing and usage through the real ingress, provider wire and settlement.
func settleOnce(t *testing.T, srv *billingFixture, ledger *payments.Ledger, model, consumerID string, usage protocol.UsageInfo) int64 {
	t.Helper()
	initial := ledger.Balance(consumerID)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	conn, _, pubKey := testkit.SetupProviderForBilling(t, ctx, ts, srv.registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")
	done := testkit.ServeOneInference(ctx, t, conn, pubKey, usage)
	body := `{"model":"` + model + `","messages":[{"role":"user","content":"hello"}],"max_tokens":8192}`
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer test-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	result, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("settlement request: %d %s", resp.StatusCode, result)
	}
	<-done
	return initial
}
