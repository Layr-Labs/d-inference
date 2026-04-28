package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/coordinator/internal/store"
)

func pricingDiscountRequest(t *testing.T, srv *Server, method, path, token, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)
	return w
}

func TestProviderPricingEndpointsAuthValidationAndOwnership(t *testing.T) {
	srv, st := testServer(t)
	const (
		accountID = "acct-pricing"
		rawToken  = "darkbloom-provider-pricing-token"
	)
	if err := st.CreateProviderToken(&store.ProviderToken{
		TokenHash: sha256HexStr(rawToken),
		AccountID: accountID,
		Label:     "pricing-test",
		Active:    true,
		CreatedAt: time.Now(),
	}); err != nil {
		t.Fatalf("CreateProviderToken: %v", err)
	}
	if err := st.UpsertProvider(context.Background(), store.ProviderRecord{
		ID:           "provider-1",
		AccountID:    accountID,
		SerialNumber: "SERIAL-1",
		SEPublicKey:  "SE-PUB-1",
		LastSeen:     time.Now(),
	}); err != nil {
		t.Fatalf("UpsertProvider: %v", err)
	}

	w := pricingDiscountRequest(t, srv, http.MethodGet, "/v1/pricing/me", rawToken, "")
	if w.Code != http.StatusOK {
		t.Fatalf("GET /v1/pricing/me status = %d body=%s", w.Code, w.Body.String())
	}
	var me struct {
		AccountID string `json:"account_id"`
		Prices    []any  `json:"prices"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &me); err != nil {
		t.Fatalf("unmarshal /pricing/me: %v", err)
	}
	if me.AccountID != accountID {
		t.Fatalf("account_id = %q, want %q", me.AccountID, accountID)
	}
	if len(me.Prices) == 0 {
		t.Fatal("/pricing/me returned no price preview rows")
	}

	w = pricingDiscountRequest(t, srv, http.MethodPut, "/v1/pricing/discount", "test-key", `{"discount_percent":10}`)
	if w.Code != http.StatusForbidden {
		t.Fatalf("API key status = %d, want 403 body=%s", w.Code, w.Body.String())
	}

	w = pricingDiscountRequest(t, srv, http.MethodPut, "/v1/pricing/discount", rawToken, `{"discount_percent":91}`)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("91%% status = %d, want 400 body=%s", w.Code, w.Body.String())
	}

	w = pricingDiscountRequest(t, srv, http.MethodPut, "/v1/pricing/discount", rawToken, `{"provider_key":"SERIAL-OTHER","discount_percent":10}`)
	if w.Code != http.StatusForbidden {
		t.Fatalf("foreign machine status = %d, want 403 body=%s", w.Code, w.Body.String())
	}

	w = pricingDiscountRequest(t, srv, http.MethodPut, "/v1/pricing/discount", rawToken, `{"provider_key":"SERIAL-1","model":"model-a","discount_percent":25}`)
	if w.Code != http.StatusOK {
		t.Fatalf("owned machine set status = %d body=%s", w.Code, w.Body.String())
	}
	d, ok := st.GetProviderDiscount(accountID, "SERIAL-1", "model-a")
	if !ok {
		t.Fatal("owned machine discount was not stored")
	}
	if d.DiscountBPS != 2500 {
		t.Fatalf("DiscountBPS = %d, want 2500", d.DiscountBPS)
	}

	w = pricingDiscountRequest(t, srv, http.MethodDelete, "/v1/pricing/discount?provider_key=SERIAL-1&model=model-a", rawToken, "")
	if w.Code != http.StatusOK {
		t.Fatalf("delete status = %d body=%s", w.Code, w.Body.String())
	}
	if _, ok := st.GetProviderDiscount(accountID, "SERIAL-1", "model-a"); ok {
		t.Fatal("discount still present after delete")
	}
}
