package testbed

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"nhooyr.io/websocket"
)

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
