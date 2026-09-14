package api

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/trustreuse"
	"os"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"net/http"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func durableTrustReuseTestServer(t *testing.T, st store.Store, journalPath string) *Server {
	t.Helper()
	logger := quietLogger()
	return NewServer(registry.New(logger), st, ServerConfig{
		DurableTrustReuse:     true,
		TrustReuseJournalPath: journalPath,
	}, logger)
}

func TestHardUntrustJournalAppendFailureLatchesRoutingClosed(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	path := filepath.Join(t.TempDir(), "coordinator", "trust-reuse-hard-untrust.v1.jsonl")
	srv := durableTrustReuseTestServer(t, mem, path)
	if err := srv.SeedTrustReuseCache(context.Background()); err != nil {
		t.Fatalf("SeedTrustReuseCache: %v", err)
	}

	rec := hardwareReuseRecord("se-append-fail", "SER-A", trHashA, time.Now())
	seedTrustReuseRecord(t, srv, rec)
	if _, err := mem.UpsertProviderTrustReuse(context.Background(), rec, 0); err != nil {
		t.Fatalf("UpsertProviderTrustReuse: %v", err)
	}

	// Make the owned journal path a directory after initialization. The real
	// append/load operation must fail before any durable revocation write.
	if err := os.Rename(path, path+".before-failure"); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(path, 0o700); err != nil {
		t.Fatal(err)
	}

	srv.trustReuse.Invalidate(rec.SEPubKey)
	blocked, reason := srv.trustSafetyStatus()
	if !blocked || reason != trustreuse.JournalHealthReason {
		t.Fatalf("append failure latch = blocked:%v reason:%q", blocked, reason)
	}
	if hasReusableTrust(srv, rec.SEPubKey, rec.Serial, trHashA) {
		t.Fatal("append failure retained reusable evidence")
	}
	ready := doReq(srv, http.MethodGet, "/readyz", "", "")
	if ready.Code != http.StatusServiceUnavailable ||
		!strings.Contains(ready.Body.String(), trustreuse.JournalHealthReason) {
		t.Fatalf("readyz did not expose fixed trust-safety reason: status=%d body=%s",
			ready.Code, ready.Body.String())
	}
	routed := doReq(srv, http.MethodPost, "/v1/chat/completions", "", minimalChatBody)
	if routed.Code != http.StatusTooManyRequests {
		t.Fatalf("trust-safety latch allowed inference routing: status=%d body=%s",
			routed.Code, routed.Body.String())
	}
}
