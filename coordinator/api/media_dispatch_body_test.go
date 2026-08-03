package api

// Regression tests for the two contracts that bind remote-media inlining to the
// rest of the request lifecycle: the body actually handed to a provider, and the
// balance reservation held while that body is in flight. Both were previously
// unpinned — every media test asserted only that the origin was hit and that the
// response was not a media-gate 4xx, which a request that fetched the image and
// then dispatched the original URL passes.

import (
	"bytes"
	"context"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"math/rand/v2"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/mediafetch"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// noisyPNG returns an incompressible 256x256 PNG (~200 KB). Real bytes matter
// here: the billing bound is a byte count, so a 2x2 fixture cannot distinguish
// "reserved against the URL" from "reserved against the inlined media".
func noisyPNG(t *testing.T) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 256, 256))
	rnd := rand.New(rand.NewPCG(1, 2))
	for y := range 256 {
		for x := range 256 {
			img.Set(x, y, color.RGBA{uint8(rnd.IntN(256)), uint8(rnd.IntN(256)), uint8(rnd.IntN(256)), 255})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("encode png: %v", err)
	}
	return buf.Bytes()
}

func loopbackMediaConfig() mediafetch.Config {
	cfg := mediafetch.DefaultConfig()
	cfg.AllowPrivateIPs = true // httptest origins are loopback
	cfg.AllowNonStandardPorts = true
	return cfg
}

// TestChatCompletionsDispatchesInlinedMediaBody is the end-to-end contract: what
// the PROVIDER receives must be the inlined data: URI, never the http(s) URL the
// consumer sent. The coordinator is the only component allowed to fetch, so a
// dispatched URL means the fetch was paid for and thrown away and the provider's
// data:-only guard will reject the request — the exact failure this feature
// exists to remove.
func TestChatCompletionsDispatchesInlinedMediaBody(t *testing.T) {
	t.Setenv("EIGENINFERENCE_MEDIA_FETCH_ALLOW_PRIVATE_IPS", "true")
	t.Setenv("EIGENINFERENCE_MEDIA_FETCH_ALLOW_NONSTANDARD_PORTS", "true")

	reg, _, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	const model = "media-inline-dispatch-model"
	fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name:      "vision-inline",
		Version:   "0.7.6",
		DecodeTPS: 200,
		Models:    []failoverModelSpec{{ID: model}},
		Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
			fp.serveFull(ctx, req, model, "ok")
		},
	})
	p := reg.GetProvider(fp.registryID)
	if p == nil {
		t.Fatal("provider missing from registry after registration")
	}
	p.Mu().Lock()
	for i := range p.Models {
		if p.Models[i].ID == model {
			p.Models[i].IsVision = true
		}
	}
	p.Mu().Unlock()

	var hits int32
	media := httptest.NewServer(pngHandler(t, &hits))
	defer media.Close()
	imageURL := media.URL + "/cat.png"

	body := `{"model":"` + model + `","max_tokens":16,"messages":[{"role":"user","content":[` +
		`{"type":"text","text":"describe"},` +
		`{"type":"image_url","image_url":{"url":"` + imageURL + `"}}]}]}`

	status, respBody, err := postChat(ctx, ts.URL, "test-key", body)
	if err != nil {
		t.Fatalf("postChat: %v", err)
	}
	if n := atomic.LoadInt32(&hits); n != 1 {
		t.Fatalf("origin hit %d time(s), want exactly 1; status=%d body=%.200s", n, status, respBody)
	}

	select {
	case got := <-fp.bodies:
		if got == nil {
			t.Fatal("provider could not decrypt the dispatched body")
		}
		if s := string(got); !strings.Contains(s, "data:image/png;base64,") {
			t.Errorf("dispatched body carries no inlined data: URI:\n%.400s", s)
		} else if strings.Contains(s, imageURL) {
			t.Errorf("dispatched body still carries the remote URL %q:\n%.400s", imageURL, s)
		}
	case <-time.After(10 * time.Second):
		t.Fatalf("provider never received an inference request (status=%d body=%.300s)", status, respBody)
	}
}

// TestChatCompletionsRemoteMediaTopsUpReservationAfterInlining pins the billing
// invariant across the fetch. estimateBillingPromptTokens is a guaranteed
// len(bytes) >= tokens upper bound, and settlement's 2x-reservation overage
// clamp relies on it — but the pre-fetch reservation sees a ~100-byte URL, not
// the media. Once inlined, the reservation must be re-taken against the real
// body; a caller funded only for the URL-shaped request must be rejected with
// its money returned, not served on a reservation that silently underpays the
// provider at settlement.
func TestChatCompletionsRemoteMediaTopsUpReservationAfterInlining(t *testing.T) {
	srv, st := testBillingServer(t)
	makeVisionRoutableProvider(t, srv.registry, "vision-topup", "test")
	srv.mediaResolver = mediafetch.NewResolver(loopbackMediaConfig(), srv.logger)
	// Non-zero input price so the prompt-token delta shows up in the reservation.
	if err := st.SetModelPrice("platform", "test", 1_000_000, 0); err != nil {
		t.Fatal(err)
	}

	var hits int32
	img := noisyPNG(t)
	media := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.Write(img)
	}))
	defer media.Close()

	_, parsed := chatBodyBytes(t, media.URL+"/noise.png")
	parsed["max_tokens"] = 1
	body, err := json.Marshal(parsed)
	if err != nil {
		t.Fatal(err)
	}

	// Fund exactly the pre-fetch reservation: enough to clear the balance gate
	// and drive the fetch, nowhere near the inlined body's byte bound.
	preFetch := srv.reservationCost("test", max(estimateBillingPromptTokens(parsed), estimatePromptTokens(parsed)), 1)
	if err := st.Credit(testConsumerID, preFetch, store.LedgerDeposit, "media-topup-floor"); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusPaymentRequired {
		t.Fatalf("status = %d, want 402 (reservation must be re-taken against the inlined body); body=%s",
			w.Code, w.Body.String())
	}
	if n := atomic.LoadInt32(&hits); n != 1 {
		t.Fatalf("origin hit %d time(s), want exactly 1 (the fetch is gated behind the pre-fetch reservation)", n)
	}
	if got := st.GetBalance(testConsumerID); got != preFetch {
		t.Errorf("balance = %d, want %d — the reservation must be fully refunded when the top-up fails", got, preFetch)
	}
}
