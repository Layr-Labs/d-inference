package api

// Regression guard for the forward-body re-marshal inflation gap.
//
// The chat handler re-marshals the parsed request body at several points before
// sealing it to a provider — including the alias-capacity fallback, which
// switches a saturated desired build to its previous build and re-serializes the
// body. If that re-marshal uses encoding/json's default Marshal, the bytes '<'
// '>' '&' are HTML-escaped into 6-byte \uXXXX forms (a ~6x inflation), so a
// benign request that fit the read cap can balloon past the provider's
// single-frame WebSocket limit and tear down its session. marshalForwardBody
// disables that escaping at every forward-marshal site; this test drives a real
// request through the alias-capacity fallback and asserts the body the provider
// actually receives is unescaped — failing if any fallback marshal site
// regresses to json.Marshal.

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestAliasCapacityFallbackForwardsUnescapedBody(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	// Keep the challenge ticker quiet for the test window: the saturated desired
	// provider is registered with a nil conn (it never receives a dispatch) and
	// shouldn't be challenged over the wire.
	srv.challengeInterval = 30 * time.Second
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	const (
		alias        = "gemma-4-fallback"
		desiredBuild = "build-desired-saturated"
		prevBuild    = "build-previous-routable"
	)

	// Desired build: a registered, trusted, SATURATED provider. The alias
	// resolves to desired (structural), but QuickCapacityCheck(desired) returns
	// 0 candidates / >0 rejections — the exact condition that fires
	// maybeFallbackAliasCapacity. nil conn is fine: it never receives a dispatch.
	registerBuildsProvider(srv, "p-desired", desiredBuild)
	pd := reg.GetProvider("p-desired")
	pd.Mu().Lock()
	pd.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 1_000
	pd.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 1_000
	pd.Mu().Unlock()

	// Previous build: a real failover provider that decrypts and captures the
	// forwarded body, then serves the request so the HTTP call completes cleanly.
	prev := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "p-prev", Version: "0.6.4", DecodeTPS: 100,
		Models: []failoverModelSpec{{ID: prevBuild}},
		Script: fullServeScript(prevBuild),
	})

	reg.SetModelAliases(map[string]registry.AliasTarget{
		alias: {Desired: desiredBuild, Previous: prevBuild},
	})

	// Sanity: desired is saturated, previous is routable — so the request must
	// take the fallback to reach a provider at all.
	if c, rej, _ := reg.QuickCapacityCheck(desiredBuild, 10, 64, registry.RequestTraits{}); c != 0 || rej == 0 {
		t.Fatalf("desired capacity = %d candidates / %d rejections, want 0 / >0 (saturated)", c, rej)
	}
	if c, _, _ := reg.QuickCapacityCheck(prevBuild, 10, 64, registry.RequestTraits{}); c == 0 {
		t.Fatal("previous build has no routable capacity (candidates=0); fallback would have nothing to switch to")
	}

	// A '<'-heavy prompt: each '<' is a benign 1 byte unescaped but a 6-byte
	// < under default HTML escaping. The run is sized so that EVEN THE
	// ESCAPED body (~6x) still fits the test WebSocket's 32 KiB default read
	// limit — so on the buggy (escaping) path the body reaches the provider WITH
	// < in it and the content assertion below is the clean discriminator,
	// rather than a frame-too-large disconnect. (In production the provider limit
	// is 32 MiB; the freeze-point cap covers genuinely oversized bodies.)
	const angleRun = 2048 // 2 KiB of '<'; ~12 KiB escaped, ~16 KiB sealed frame
	content := strings.Repeat("<", angleRun)
	chatBody := fmt.Sprintf(
		`{"model":%q,"messages":[{"role":"user","content":%q}],"stream":true,"max_tokens":64}`,
		alias, content)

	status, respBody, err := postChat(ctx, ts.URL, "test-key", chatBody)
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	if status != http.StatusOK {
		t.Fatalf("status = %d, want 200 (fallback should route to the previous build); body = %s", status, respBody)
	}

	// Inspect the body the provider actually received post-fallback.
	var got []byte
	select {
	case got = <-prev.bodies:
	case <-time.After(5 * time.Second):
		t.Fatal("previous provider never received a dispatch — the fallback did not route here")
	}
	if got == nil {
		t.Fatal("previous provider could not decrypt the forwarded body")
	}

	// The 6-byte JSON escape for '<' is the ASCII run \ u 0 0 3 c. Its presence
	// means a fallback marshal site regressed to the HTML-escaping json.Marshal.
	if bytes.Contains(got, []byte{'\\', 'u', '0', '0', '3', 'c'}) {
		t.Fatal("forwarded body HTML-escaped '<' to \\u003c — an alias-capacity fallback re-marshal regressed to json.Marshal")
	}
	if !bytes.Contains(got, bytes.Repeat([]byte("<"), 64)) {
		t.Fatalf("forwarded body is missing the raw '<' run (len=%d)", len(got))
	}
	// The unescaped body tracks the input; the escaped form would be ~6x larger.
	if len(got) > angleRun+8192 {
		t.Fatalf("forwarded body unexpectedly large: %d bytes (input ~%d) — inflation suggests escaping crept back in", len(got), angleRun)
	}
}
