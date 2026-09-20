package api

import (
	"encoding/json"
	"errors"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestReferralInfoUnregisteredConsumer(t *testing.T) {
	srv, _, _ := billingTestServer(t)
	w := httptest.NewRecorder()
	srv.handleReferralInfo(w, reqWithUser(http.MethodGet, "/v1/referral/info", "", "consumer"))
	if w.Code != http.StatusOK {
		t.Fatalf("status %d: %s", w.Code, w.Body.String())
	}
	var info map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &info); err != nil {
		t.Fatal(err)
	}
	if info["code"] != "" || info["referred_by"] != "" || info["share_percent"] != float64(5) || info["reward_basis"] != "consumer_spend" {
		t.Fatalf("unexpected info: %v", info)
	}
}

func TestReferralHandlersRegisterApplyInfo(t *testing.T) {
	srv, _, _ := billingTestServer(t)
	w := httptest.NewRecorder()
	srv.handleReferralRegister(w, reqWithUser(http.MethodPost, "/v1/referral/register", `{"code":"partner"}`, "partner"))
	if w.Code != http.StatusOK {
		t.Fatalf("register: %d %s", w.Code, w.Body.String())
	}
	for i := 0; i < 2; i++ {
		w = httptest.NewRecorder()
		srv.handleReferralApply(w, reqWithUser(http.MethodPost, "/v1/referral/apply", `{"code":" partner "}`, "consumer"))
		if w.Code != http.StatusOK {
			t.Fatalf("apply %d: %d %s", i, w.Code, w.Body.String())
		}
		var response map[string]any
		_ = json.Unmarshal(w.Body.Bytes(), &response)
		if response["code"] != "PARTNER" {
			t.Fatalf("unnormalized response: %v", response)
		}
	}
	w = httptest.NewRecorder()
	srv.handleReferralInfo(w, reqWithUser(http.MethodGet, "/v1/referral/info", "", "consumer"))
	var info map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &info)
	if info["referred_by"] != "PARTNER" {
		t.Fatalf("missing attribution: %d %v", w.Code, info)
	}
}

func TestReferralMutationRequiresPrivy(t *testing.T) {
	srv, _, _ := billingTestServer(t)
	for _, handler := range []http.HandlerFunc{srv.handleReferralRegister, srv.handleReferralApply} {
		w := httptest.NewRecorder()
		handler(w, httptest.NewRequest(http.MethodPost, "/v1/referral/register", nil))
		if w.Code != http.StatusForbidden && w.Code != http.StatusUnauthorized {
			t.Fatalf("unauthenticated mutation: %d", w.Code)
		}
	}
}

type referralUnavailableStore struct{ store.Store }

func (s referralUnavailableStore) GetReferrerByAccount(string) (*store.Referrer, error) {
	return nil, errors.New("private database connection details")
}

func TestReferralReadOutageIsRetryableAndSanitized(t *testing.T) {
	srv, st, _ := billingTestServer(t)
	srv.SetBilling(billing.NewService(referralUnavailableStore{st}, srv.ledger, srv.logger, billing.Config{}))
	for _, handler := range []http.HandlerFunc{srv.handleReferralInfo, srv.handleReferralStats} {
		w := httptest.NewRecorder()
		handler(w, reqWithUser(http.MethodGet, "/v1/referral/info", "", "consumer"))
		if w.Code != http.StatusServiceUnavailable {
			t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
		}
		if strings.Contains(w.Body.String(), "private database") {
			t.Fatal("leaked internal error")
		}
	}
}
