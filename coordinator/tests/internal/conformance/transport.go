package conformance

import (
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

func (s Suite) TestOpenRouterConformanceTransport(t *testing.T) {
	var otherHits, originHits atomic.Int32
	other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { otherHits.Add(1) }))
	defer other.Close()
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		originHits.Add(1)
		http.Redirect(w, r, other.URL, http.StatusTemporaryRedirect)
	}))
	defer origin.Close()
	client := orLoopbackClient(t, origin.URL)
	defer client.CloseIdleConnections()
	t.Run("redirect_denied", func(t *testing.T) {
		resp, err := client.Get(origin.URL)
		if resp != nil {
			resp.Body.Close()
		}
		if err == nil || originHits.Load() != 1 || otherHits.Load() != 0 {
			t.Fatalf("redirect/retry guard: err=%v origin=%d other=%d", err, originHits.Load(), otherHits.Load())
		}
	})
	t.Run("alternate_destination_denied", func(t *testing.T) {
		resp, err := client.Get(other.URL)
		if resp != nil {
			resp.Body.Close()
		}
		if err == nil || otherHits.Load() != 0 {
			t.Fatal("non-fixture listener was reachable")
		}
	})
	t.Run("proxy_disabled", func(t *testing.T) {
		if client.Transport.(*http.Transport).Proxy != nil {
			t.Fatal("proxy inheritance enabled")
		}
	})
}
