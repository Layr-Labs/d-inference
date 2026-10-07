package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestDesktopAccountGrantIsPurposeBoundAndSingleUse(t *testing.T) {
	srv, st := deviceTestServer()
	w := httptest.NewRecorder()
	srv.handleDeviceCode(w, httptest.NewRequest("POST", "/v1/device/code", strings.NewReader(`{"purpose":"desktop_account"}`)))
	var code struct {
		Device  string `json:"device_code"`
		User    string `json:"user_code"`
		Purpose string `json:"purpose"`
		URL     string `json:"verification_uri"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &code); err != nil || w.Code != 200 || code.Purpose != desktopAccountPurpose || !strings.Contains(code.URL, "purpose=desktop_account") {
		t.Fatalf("bad grant: %s", w.Body)
	}
	approve := func(purpose string) int {
		req := httptest.NewRequest("POST", "/v1/device/approve", strings.NewReader(`{"user_code":"`+code.User+`","purpose":"`+purpose+`"}`))
		req = req.WithContext(withUser(req.Context(), "owner", "owner@example.com"))
		w := httptest.NewRecorder()
		srv.handleDeviceApprove(w, req)
		return w.Code
	}
	if approve("provider") != 400 {
		t.Fatal("provider consent granted account access")
	}
	if approve(desktopAccountPurpose) != 200 {
		t.Fatal("account approval failed")
	}
	var successes atomic.Int32
	var wg sync.WaitGroup
	for range 16 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			req := httptest.NewRequest("POST", "/v1/device/token", strings.NewReader(`{"device_code":"`+code.Device+`"}`))
			w := httptest.NewRecorder()
			srv.handleDeviceToken(w, req)
			if w.Code == 200 {
				successes.Add(1)
			}
		}()
	}
	wg.Wait()
	if successes.Load() != 1 {
		t.Fatalf("grant exchanged %d times", successes.Load())
	}
	dc, _ := st.GetDeviceCode(code.Device)
	if dc.Status != "consumed" {
		t.Fatal("grant not consumed")
	}
}

func TestDesktopAccountScopeOwnerExpiryAndRevocation(t *testing.T) {
	srv, st := deviceTestServer()
	if err := st.CreateUser(&store.User{AccountID: "owner", PrivyUserID: "did:privy:owner", Email: "owner@example.com"}); err != nil {
		t.Fatal(err)
	}
	token := desktopAccountTokenPrefix + strings.Repeat("a", 64)
	pt := &store.ProviderToken{TokenHash: sha256Hash(token), AccountID: "owner", Active: true, Label: desktopAccountCodePrefix + "TEST", CreatedAt: time.Now()}
	if err := st.CreateProviderToken(pt); err != nil {
		t.Fatal(err)
	}
	request := func(method, path string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, path, nil)
		req.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)
		return w
	}
	for _, path := range []string{"/v1/me/providers", "/v1/me/summary", "/v1/provider/account-earnings?account_id=other", "/v1/provider/account-earnings?window=7d"} {
		w := request("GET", path)
		if w.Code != 200 || strings.Contains(w.Body.String(), `"account_id":"other"`) {
			t.Fatalf("%s: %d %s", path, w.Code, w.Body)
		}
	}
	for _, route := range []struct{ method, path string }{{"GET", "/v1/payments/balance"}, {"POST", "/v1/chat/completions"}, {"POST", "/v1/device/approve"}, {"DELETE", "/v1/me/providers/machine"}, {"GET", "/v1/provider/desktop"}} {
		w := request(route.method, route.path)
		if w.Code != http.StatusUnauthorized && w.Code != http.StatusForbidden {
			t.Fatalf("scope escape: %s %d", route.path, w.Code)
		}
	}
	if request("DELETE", "/v1/device/token").Code != 204 {
		t.Fatal("revoke failed")
	}
	if request("GET", "/v1/me/providers").Code != 401 {
		t.Fatal("revoked token used cached account data")
	}
	expired := desktopAccountTokenPrefix + strings.Repeat("b", 64)
	pt.TokenHash = sha256Hash(expired)
	pt.CreatedAt = time.Now().Add(-desktopAccountLifetime - time.Minute)
	if err := st.CreateProviderToken(pt); err != nil {
		t.Fatal(err)
	}
	token = expired
	if request("GET", "/v1/me/summary").Code != 401 {
		t.Fatal("expired session accepted")
	}
}

func TestAccountEarningsWindowIncludesRowsBeyondRecentPage(t *testing.T) {
	srv, st := deviceTestServer()
	now := time.Now().UTC()
	for i := 0; i < 1002; i++ {
		row := &store.ProviderEarning{AccountID: "owner", JobID: fmt.Sprintf("job-%d", i), Model: "model", ProviderID: "machine", AmountMicroUSD: 1, PromptTokens: 2, CompletionTokens: 3, CreatedAt: now.Add(-time.Hour)}
		if err := st.RecordProviderEarning(row); err != nil {
			t.Fatal(err)
		}
	}
	req := httptest.NewRequest("GET", "/v1/provider/account-earnings?window=7d&limit=1", nil)
	req = req.WithContext(context.WithValue(req.Context(), ctxKeyConsumer, "owner"))
	w := httptest.NewRecorder()
	srv.handleAccountEarnings(w, req)
	var result desktopInsights
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil || w.Code != 200 {
		t.Fatalf("aggregate failed %s", w.Body)
	}
	if result.Totals.Jobs != 1002 || result.Totals.WorkMicroUSD != 1002 || len(result.Days) != 7 {
		t.Fatalf("truncated aggregate: %+v", result)
	}
}
