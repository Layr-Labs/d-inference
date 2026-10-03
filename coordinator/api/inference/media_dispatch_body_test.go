package inference

import (
	"bytes"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"math/rand/v2"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/mediafetch"
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
	if err := st.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: "test", InputPrice: 1_000_000, OutputPrice: 0}); err != nil {
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
	preFetch := srv.reservationCost("test", max(inreq.EstimateBillingPromptTokens(parsed), inreq.EstimatePromptTokens(parsed)), 1)
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
