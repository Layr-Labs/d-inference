package api

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

func TestInputTokenFloorAliasRechecksInlinedMedia(t *testing.T) {
	t.Setenv("EIGENINFERENCE_MEDIA_FETCH_ALLOW_PRIVATE_IPS", "true")
	t.Setenv("EIGENINFERENCE_MEDIA_FETCH_ALLOW_NONSTANDARD_PORTS", "true")
	for _, previousFloor := range []int{32, 1000} {
		t.Run(map[int]string{32: "compatible fallback", 1000: "fallback fails floor"}[previousFloor], func(t *testing.T) {
			h := newRuntimeDefaultsAliasHarness(t, map[string]any{"min_input_tokens": 32}, map[string]any{"min_input_tokens": previousFloor})
			h.providers[0].conn.SetReadLimit(64 << 20)           // ciphertext base64 exceeds the plaintext limit
			h.coordinator.firstContentDeadlineBase = time.Minute // race-instrumented 16 MiB serialization
			t.Cleanup(func() {
				h.providers[0].closeNow()
				<-h.providers[0].done
			})
			ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
			defer cancel()
			// Desired fits the URL form, but only Previous supports an inlined body
			// this close to the wire limit without adding a legacy cache buster.
			for _, id := range []string{"runtime-defaults-desired-provider", h.providers[0].registryID} {
				p := h.coordinator.registry.GetProvider(id)
				p.Mu().Lock()
				p.Version = "0.7.6"
				for i := range p.Models {
					p.Models[i].IsVision = true
				}
				if p.BackendCapacity != nil {
					p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 0
					p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 100000
				}
				p.Mu().Unlock()
			}
			setPrefixCacheProtocol(t, h.coordinator.registry, h.providers[0], 1)
			png := noisyPNG(t)
			var hits atomic.Int32
			origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				hits.Add(1)
				w.Header().Set("Content-Type", "image/png")
				_, _ = w.Write(png)
			}))
			defer origin.Close()
			image := map[string]any{"url": "data:image/png;base64," + base64.StdEncoding.EncodeToString(png)}
			parsed := map[string]any{"model": runtimeDefaultsDesiredModel, "messages": []any{map[string]any{"role": "user", "content": []any{map[string]any{"type": "text", "text": "describe"}, map[string]any{"type": "image_url", "image_url": image}}}}, "max_tokens": 16, "padding": ""}
			promptcontract.SetRequestDate(parsed, time.Now())
			encoded, err := marshalForwardBody(parsed)
			if err != nil {
				t.Fatal(err)
			}
			parsed["padding"] = strings.Repeat("x", maxInferenceBodyBytes-len(encoded)-16)
			encoded, err = marshalForwardBody(parsed)
			if err != nil {
				t.Fatal(err)
			}
			traits, err := routingTraitsForProviderBody(true, encoded, false)
			if err == nil || traits.MinPrefixCacheProtocol != 1 {
				t.Fatalf("fixture does not require protocol 1: %+v %v", traits, err)
			}
			image["url"] = origin.URL + "/image.png"
			parsed["model"] = runtimeDefaultsAlias
			body, _ := json.Marshal(parsed)
			status, response, err := postChat(ctx, h.server.URL, "test-key", string(body))
			if err != nil {
				t.Fatal(err)
			}
			if hits.Load() != 1 {
				t.Fatalf("media fetches=%d want1, status=%d body=%.300s", hits.Load(), status, response)
			}
			if previousFloor == 32 {
				if status != 200 {
					t.Fatalf("status=%d want200 body=%.300s", status, response)
				}
				fields := readRuntimeDefaultsProviderBody(t, h.providers[0])
				if string(fields["model"]) != `"`+runtimeDefaultsPreviousModel+`"` || !strings.Contains(string(fields["messages"]), "data:image/png;base64,") {
					t.Fatal("fallback did not receive the inlined body")
				}
			} else {
				if status != 413 || !strings.Contains(string(response), "payload_too_large") {
					t.Fatalf("status=%d want413 body=%.300s", status, response)
				}
				if h.providers[0].dispatchCount() != 0 {
					t.Fatal("inlined request fell back to a build whose floor failed")
				}
			}
		})
	}
}
