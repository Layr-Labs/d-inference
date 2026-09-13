package testbed

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"nhooyr.io/websocket"
)

func TestProviderWireRelayPreservesCoordinatorHTTP(t *testing.T) {
	for _, tc := range []struct {
		path   string
		status int
		body   string
	}{
		{"/v1/models/catalog?model=gemma-4-26b-qat-4bit", http.StatusOK, `{"metadata":{"spec_dec":{"revision":"pinned-assistant"}}}`},
		{"/v1/models/catalog", http.StatusServiceUnavailable, `{"error":"catalog unavailable"}`},
		{"/v1/models/catalog/manifest/EigenLabs%2Fmodel", http.StatusOK, `{"files":[]}`},
	} {
		t.Run(http.StatusText(tc.status), func(t *testing.T) {
			seen := make(chan *http.Request, 1)
			backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				seen <- req
				w.Header().Set("Content-Type", "application/json")
				w.Header().Set("ETag", `"catalog-version"`)
				w.WriteHeader(tc.status)
				_, _ = io.WriteString(w, tc.body)
			}))
			defer backend.Close()
			relay := &ProviderWireRelay{}
			url := relay.Start(backend.URL)
			defer relay.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			req, err := http.NewRequestWithContext(ctx, http.MethodGet, url+tc.path, nil)
			require.NoError(t, err)
			req.Header.Set("Authorization", "Bearer fixture-token")
			req.Header.Set("If-None-Match", `"previous-catalog"`)
			response, err := http.DefaultClient.Do(req)
			require.NoError(t, err)
			defer response.Body.Close()
			body, err := io.ReadAll(response.Body)
			require.NoError(t, err)
			require.Equal(t, tc.status, response.StatusCode)
			require.Equal(t, tc.body, string(body))
			require.Equal(t, "application/json", response.Header.Get("Content-Type"))
			require.Equal(t, `"catalog-version"`, response.Header.Get("ETag"))
			select {
			case forwarded := <-seen:
				require.Equal(t, http.MethodGet, forwarded.Method)
				require.Equal(t, tc.path, forwarded.URL.RequestURI())
				require.Equal(t, "Bearer fixture-token", forwarded.Header.Get("Authorization"))
				require.Equal(t, `"previous-catalog"`, forwarded.Header.Get("If-None-Match"))
			case <-ctx.Done():
				t.Fatal(ctx.Err())
			}
			events, dropped := relay.Snapshot()
			require.Empty(t, events)
			require.Zero(t, dropped)
		})
	}
}

func TestProviderWireRelayRejectsOtherHTTPRoutes(t *testing.T) {
	var requests atomic.Int64
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		requests.Add(1)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer backend.Close()
	relay := &ProviderWireRelay{}
	url := relay.Start(backend.URL)
	defer relay.Close()
	for _, tc := range []struct{ method, path string }{
		{http.MethodGet, "/v1/admin/models"},
		{http.MethodPost, "/v1/admin/credits"},
		{http.MethodGet, "/v1/models/catalogue"},
		{http.MethodPost, "/v1/models/catalog"},
		{http.MethodPost, "/v1/models/catalog/manifest/model"},
		{http.MethodGet, "/v1/models/catalog/manifest/../../admin/models"},
	} {
		t.Run(tc.method+tc.path, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			req, err := http.NewRequestWithContext(ctx, tc.method, url+tc.path, nil)
			require.NoError(t, err)
			req.Header.Set("Authorization", "Bearer testbed-admin-key")
			response, err := http.DefaultClient.Do(req)
			require.NoError(t, err)
			response.Body.Close()
			require.Equal(t, http.StatusNotFound, response.StatusCode)
		})
	}
	require.Zero(t, requests.Load(), "blocked requests must never reach the coordinator")
}

func TestProviderWireRelayCloseCancelsCoordinatorHTTP(t *testing.T) {
	started, canceled := make(chan struct{}), make(chan struct{})
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		close(started)
		<-req.Context().Done()
		close(canceled)
	}))
	defer backend.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	relay := &ProviderWireRelay{}
	url := relay.Start(backend.URL)
	defer relay.Close()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url+"/v1/models/catalog", nil)
	require.NoError(t, err)
	clientDone := make(chan struct{})
	go func() {
		defer close(clientDone)
		if response, err := http.DefaultClient.Do(req); err == nil {
			response.Body.Close()
		}
	}()
	select {
	case <-started:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	relay.Close()
	for _, done := range []<-chan struct{}{canceled, clientDone} {
		select {
		case <-done:
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		}
	}
	require.NoError(t, ctx.Err(), "relay close must cancel HTTP before the client timeout")
}

func TestProviderWireRelayPreservesTransport(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	input := `{"type":"inference_request","request_id":"r","encrypted_body":{"ciphertext":"unchanged-secret"},"cache_scope":"tenant-secret","cache_receipt_nonce":"nonce-secret","cache_receipt_boundary_mode":"checkpoint"}`
	terminal := `{"type":"inference_complete","request_id":"r","usage":{"cached_tokens":1024}}`
	seen := make(chan string, 1)
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer fixture-token" {
			http.Error(w, "unauthorized", 401)
			return
		}
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer c.CloseNow()
		if c.Write(ctx, websocket.MessageText, []byte(input)) != nil {
			return
		}
		_, data, err := c.Read(ctx)
		if err == nil {
			seen <- string(data)
		}
	}))
	defer backend.Close()
	relay := &ProviderWireRelay{}
	url := relay.Start(backend.URL)
	defer relay.Close()
	c, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(url, "http")+"/ws/provider", &websocket.DialOptions{HTTPHeader: http.Header{"Authorization": []string{"Bearer fixture-token"}}})
	require.NoError(t, err)
	defer c.CloseNow()
	_, data, err := c.Read(ctx)
	require.NoError(t, err)
	require.Equal(t, input, string(data))
	require.NoError(t, c.Write(ctx, websocket.MessageText, []byte(terminal)))
	select {
	case got := <-seen:
		require.Equal(t, terminal, got)
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	events, dropped := relay.Snapshot()
	require.Zero(t, dropped)
	require.Len(t, events, 2)
	serialized, err := json.Marshal(events)
	require.NoError(t, err)
	for _, secret := range []string{"unchanged-secret", "tenant-secret", "nonce-secret", "fixture-token"} {
		require.NotContains(t, string(serialized), secret)
	}
	require.Equal(t, json.RawMessage("true"), events[0].Fields["encrypted_body_present"])
	require.Equal(t, events[0].Connection, events[1].Connection)
}

func TestProviderWireRelayCapacityObservationsRemainNarrow(t *testing.T) {
	for _, tc := range []struct {
		frame string
		want  string
	}{
		{`{"type":"capacity_probe","quote_id":"random-probe","model":"model","prompt_tokens_bucket":512,"max_output_tokens":1,"auth_token":"secret","prompt":"secret","encrypted_body":"secret"}`, `{"quote_id":"random-probe","model":"model"}`},
		{`{"type":"capacity_quote","quote_id":"random-probe","capacity_seq":5,"admissible_now":false,"rejection_reason":"slot_state","ttft_p90_ms":200,"auth_token":"secret","prompt":"secret","cache_scope":"secret"}`, `{"quote_id":"random-probe","capacity_seq":5,"admissible_now":false,"rejection_reason":"slot_state"}`},
	} {
		event, ok := summarizeProviderFrame([]byte(tc.frame))
		require.True(t, ok)
		raw, err := json.Marshal(event.Fields)
		require.NoError(t, err)
		require.JSONEq(t, tc.want, string(raw))
		require.NotContains(t, string(raw), "secret")
	}
}

func TestProviderWireRelayRedactsAnchorsAndBounds(t *testing.T) {
	relay := &ProviderWireRelay{}
	for i := 0; i < 4097; i++ {
		relay.observe(1, "provider_to_coordinator", []byte(`{"type":"prefix_cache_ready_v2","request_id":"r","ready_anchors":[{"token_count":1024,"chain_hash":"secret-chain"}],"cache_receipt_nonce":"secret-nonce"}`))
	}
	events, dropped := relay.Snapshot()
	require.Len(t, events, 4096)
	require.Equal(t, 1, dropped)
	require.Equal(t, json.RawMessage("[1024]"), events[0].Fields["ready_positions"])
	serialized, _ := json.Marshal(events)
	require.NotContains(t, string(serialized), "secret")
}
func TestProviderWireRelayForwardsCancellationAndCloses(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer c.CloseNow()
		_ = c.Write(ctx, websocket.MessageText, []byte(`{"type":"cancel","request_id":"cancel-r"}`))
		_, _, _ = c.Read(ctx)
	}))
	defer backend.Close()
	relay := &ProviderWireRelay{}
	url := relay.Start(backend.URL)
	c, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(url, "http")+"/ws/provider", nil)
	require.NoError(t, err)
	defer c.CloseNow()
	_, data, err := c.Read(ctx)
	require.NoError(t, err)
	require.JSONEq(t, `{"type":"cancel","request_id":"cancel-r"}`, string(data))
	relay.Close()
	_, _, err = c.Read(ctx)
	require.Error(t, err)
}
func TestProviderTOMLExplicitNormalMTP(t *testing.T) {
	for _, mode := range []string{"on", "off"} {
		config, err := BuildProviderTOML(ProviderConfig{MTPMode: mode, MTPDrafterPath: "/fixture/assistant"}, 0)
		require.NoError(t, err)
		require.Contains(t, config, "config_version = 3")
		require.Contains(t, config, `mtp_mode = "`+mode+`"`)
		require.Contains(t, config, `mtp_drafter_path = "/fixture/assistant"`)
	}
	_, err := BuildProviderTOML(ProviderConfig{MTPMode: "disable-for-test"}, 0)
	require.Error(t, err)
}

func TestProviderWireRelayRetainsTypedProfileOnly(t *testing.T) {
	event, ok := summarizeProviderFrame([]byte(`{"type":"inference_complete","request_id":"r","usage":{"completion_tokens":2,"prompt_secret":"do-not-store"},"profile":{"mtp_active":true,"cancel_received_us":20,"cancel_aborted_us":30,"unknown_secret":"do-not-store"}}`))
	require.True(t, ok)
	raw, err := json.Marshal(event)
	require.NoError(t, err)
	require.NotContains(t, string(raw), "do-not-store")
	require.Contains(t, string(raw), "cancel_aborted_us")
}
