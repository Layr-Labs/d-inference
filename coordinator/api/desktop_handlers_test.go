package api

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestDesktopAccountTokenIsolationAndRevocation(t *testing.T) {
	srv, _ := testServer(t)
	digest := sha256.Sum256([]byte("desktop-test-token"))
	if err := srv.store.CreateProviderToken(&store.ProviderToken{TokenHash: hex.EncodeToString(digest[:]), AccountID: "desktop-owner", Active: true}); err != nil {
		t.Fatal(err)
	}
	for _, owner := range []string{"desktop-owner", "another-owner"} {
		if err := srv.store.UpsertProvider(context.Background(), store.ProviderRecord{ID: owner + "-node", AccountID: owner,
			Hardware: json.RawMessage(`{"chip_name":"Apple test","memory_gb":64}`), Models: json.RawMessage(`[]`),
			SEPublicKey: "secret-key-" + owner, LastSeen: time.Now()}); err != nil {
			t.Fatal(err)
		}
	}
	server := httptest.NewServer(srv.Handler())
	defer server.Close()
	read := func(token string) (int, string) {
		t.Helper()
		req, _ := http.NewRequest(http.MethodGet, server.URL+"/v1/provider/desktop", nil)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		resp, err := server.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(body)
	}
	if code, _ := read(""); code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated code=%d", code)
	}
	code, body := read("desktop-test-token")
	if code != http.StatusOK || !strings.Contains(body, "desktop-owner-node") {
		t.Fatalf("%d: %s", code, body)
	}
	for _, forbidden := range []string{"another-owner", "secret-key", "se_public_key", "provider_key", "system_volume_hash"} {
		if strings.Contains(body, forbidden) {
			t.Fatalf("leaked %s: %s", forbidden, body)
		}
	}
	if err := srv.store.RevokeProviderToken("desktop-test-token"); err != nil {
		t.Fatal(err)
	}
	if code, _ := read("desktop-test-token"); code != http.StatusUnauthorized {
		t.Fatalf("cached response survived revocation: %d", code)
	}
}

func TestDesktopMachineEarningsDoNotCrossAccountTransfers(t *testing.T) {
	st := store.NewMemory(store.Config{})
	now := time.Now()
	for i, earning := range []store.ProviderEarning{
		{AccountID: "current-owner", ProviderKey: "shared-key", Model: "model", AmountMicroUSD: 40},
		{AccountID: "old-owner", ProviderKey: "shared-key", Model: "model", AmountMicroUSD: 900},
		{AccountID: "current-owner", ProviderKey: "shared-key", Model: "base_reward", AmountMicroUSD: 500},
	} {
		earning.CreatedAt = now.Add(-time.Minute)
		earning.JobID = string(rune('a' + i))
		if err := st.RecordProviderEarning(&earning); err != nil {
			t.Fatal(err)
		}
	}
	result := desktopUsageEarnings(context.Background(), store.NewCached(st, store.DefaultCacheConfig()), "current-owner", "shared-key", now)
	if result == nil || *result != "40" {
		t.Fatalf("account-scoped usage amount = %v, want 40", result)
	}
	if value := desktopUsageEarnings(context.Background(), st, "current-owner", "", now); value != nil {
		t.Fatal("missing attribution must remain unknown")
	}
}
