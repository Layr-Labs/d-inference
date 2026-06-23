package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

func TestProviderControlSocketAttachReceivesControlFrames(t *testing.T) {
	logger := slog.Default()
	reg := registry.New(logger)
	srv := NewServer(reg, store.NewMemory(store.Config{}), ServerConfig{}, logger)
	srv.SetSkipChallenge(true)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	dataURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	dataConn, _, err := websocket.Dial(ctx, dataURL, nil)
	if err != nil {
		t.Fatalf("dial data websocket: %v", err)
	}
	defer dataConn.Close(websocket.StatusNormalClosure, "")

	register := protocol.RegisterMessage{
		Type:    protocol.TypeRegister,
		Version: minProviderVersionForControlSocket,
		Backend: registry.BackendMLXSwift,
		Hardware: protocol.Hardware{
			MachineModel: "Mac14,2",
			ChipName:     "M2",
			MemoryGB:     16,
		},
		Models: []protocol.ModelInfo{{ID: "model-a", SizeBytes: 1}},
	}
	regBytes, err := json.Marshal(register)
	if err != nil {
		t.Fatalf("marshal register: %v", err)
	}
	if err := dataConn.Write(ctx, websocket.MessageText, regBytes); err != nil {
		t.Fatalf("write register: %v", err)
	}

	_, inviteBytes, err := dataConn.Read(ctx)
	if err != nil {
		t.Fatalf("read control invite: %v", err)
	}
	var invite protocol.ControlSocketMessage
	if err := json.Unmarshal(inviteBytes, &invite); err != nil {
		t.Fatalf("unmarshal invite: %v", err)
	}
	if invite.Type != protocol.TypeControlSocket || invite.URL == "" {
		t.Fatalf("bad control invite: %+v", invite)
	}
	inviteURL, err := url.Parse(invite.URL)
	if err != nil {
		t.Fatalf("parse invite URL: %v", err)
	}
	providerID := inviteURL.Query().Get("provider_id")
	if providerID == "" {
		t.Fatalf("invite URL missing provider_id: %s", invite.URL)
	}

	controlConn, _, err := websocket.Dial(ctx, invite.URL, nil)
	if err != nil {
		t.Fatalf("dial control websocket: %v", err)
	}
	defer controlConn.Close(websocket.StatusNormalClosure, "")

	provider := reg.GetProvider(providerID)
	if provider == nil {
		t.Fatalf("provider %q not found", providerID)
	}

	cancelMsg := protocol.CancelMessage{Type: protocol.TypeCancel, RequestID: "req-control"}
	cancelBytes, err := json.Marshal(cancelMsg)
	if err != nil {
		t.Fatalf("marshal cancel: %v", err)
	}
	if err := provider.WriteControlText(ctx, cancelBytes); err != nil {
		t.Fatalf("write control frame: %v", err)
	}
	_, gotControl, err := controlConn.Read(ctx)
	if err != nil {
		t.Fatalf("read control frame: %v", err)
	}
	if string(gotControl) != string(cancelBytes) {
		t.Fatalf("control frame = %s, want %s", gotControl, cancelBytes)
	}

	inferMsg := protocol.InferenceRequestMessage{Type: protocol.TypeInferenceRequest, RequestID: "req-data"}
	inferBytes, err := json.Marshal(inferMsg)
	if err != nil {
		t.Fatalf("marshal inference request: %v", err)
	}
	if err := provider.WriteText(ctx, inferBytes); err != nil {
		t.Fatalf("write data frame: %v", err)
	}
	var gotData []byte
	for {
		_, gotData, err = dataConn.Read(ctx)
		if err != nil {
			t.Fatalf("read data frame: %v", err)
		}
		var envelope struct {
			Type string `json:"type"`
		}
		if json.Unmarshal(gotData, &envelope) == nil && envelope.Type == protocol.TypeInferenceRequest {
			break
		}
	}
	if string(gotData) != string(inferBytes) {
		t.Fatalf("data frame = %s, want %s", gotData, inferBytes)
	}
}

func TestProviderControlSocketInviteIsVersionGated(t *testing.T) {
	logger := slog.Default()
	reg := registry.New(logger)
	srv := NewServer(reg, store.NewMemory(store.Config{}), ServerConfig{}, logger)
	srv.SetSkipChallenge(true)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	dataConn, err := dialAndRegisterControlSocketTestProvider(ctx, ts.URL, "0.6.17")
	if err != nil {
		t.Fatalf("register legacy provider: %v", err)
	}
	defer dataConn.Close(websocket.StatusNormalClosure, "")

	readCtx, cancelRead := context.WithTimeout(context.Background(), 250*time.Millisecond)
	defer cancelRead()
	for {
		_, msg, err := dataConn.Read(readCtx)
		if err != nil {
			return
		}
		var envelope struct {
			Type string `json:"type"`
		}
		if json.Unmarshal(msg, &envelope) == nil && envelope.Type == protocol.TypeControlSocket {
			t.Fatalf("legacy provider received control_socket invite: %s", msg)
		}
	}
}

func TestProviderControlSocketTokenIsOneTimeUse(t *testing.T) {
	logger := slog.Default()
	reg := registry.New(logger)
	srv := NewServer(reg, store.NewMemory(store.Config{}), ServerConfig{}, logger)
	srv.SetSkipChallenge(true)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	dataConn, err := dialAndRegisterControlSocketTestProvider(ctx, ts.URL, minProviderVersionForControlSocket)
	if err != nil {
		t.Fatalf("register provider: %v", err)
	}
	defer dataConn.Close(websocket.StatusNormalClosure, "")

	invite := readControlSocketInvite(t, ctx, dataConn)
	first, _, err := websocket.Dial(ctx, invite.URL, nil)
	if err != nil {
		t.Fatalf("first control dial: %v", err)
	}
	defer first.Close(websocket.StatusNormalClosure, "")

	second, resp, err := websocket.Dial(ctx, invite.URL, nil)
	if err == nil {
		second.Close(websocket.StatusNormalClosure, "")
		t.Fatal("second control dial unexpectedly succeeded")
	}
	if resp == nil || resp.StatusCode != 401 {
		if resp == nil {
			t.Fatalf("second dial status = nil response, err=%v", err)
		}
		t.Fatalf("second dial status = %d, want 401; err=%v", resp.StatusCode, err)
	}
}

func dialAndRegisterControlSocketTestProvider(ctx context.Context, serverURL, version string) (*websocket.Conn, error) {
	dataURL := "ws" + strings.TrimPrefix(serverURL, "http") + "/ws/provider"
	dataConn, _, err := websocket.Dial(ctx, dataURL, nil)
	if err != nil {
		return nil, err
	}
	register := protocol.RegisterMessage{
		Type:    protocol.TypeRegister,
		Version: version,
		Backend: registry.BackendMLXSwift,
		Hardware: protocol.Hardware{
			MachineModel: "Mac14,2",
			ChipName:     "M2",
			MemoryGB:     16,
		},
		Models: []protocol.ModelInfo{{ID: "model-a", SizeBytes: 1}},
	}
	regBytes, err := json.Marshal(register)
	if err != nil {
		dataConn.CloseNow()
		return nil, err
	}
	if err := dataConn.Write(ctx, websocket.MessageText, regBytes); err != nil {
		dataConn.CloseNow()
		return nil, err
	}
	return dataConn, nil
}

func readControlSocketInvite(t *testing.T, ctx context.Context, conn *websocket.Conn) protocol.ControlSocketMessage {
	t.Helper()
	for {
		_, msg, err := conn.Read(ctx)
		if err != nil {
			t.Fatalf("read control invite: %v", err)
		}
		var envelope struct {
			Type string `json:"type"`
		}
		if json.Unmarshal(msg, &envelope) != nil || envelope.Type != protocol.TypeControlSocket {
			continue
		}
		var invite protocol.ControlSocketMessage
		if err := json.Unmarshal(msg, &invite); err != nil {
			t.Fatalf("unmarshal invite: %v", err)
		}
		if invite.URL == "" {
			t.Fatalf("control invite missing URL: %+v", invite)
		}
		return invite
	}
}
