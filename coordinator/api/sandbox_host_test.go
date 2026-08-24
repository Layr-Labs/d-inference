package api

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/sandboxhost"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

const (
	testSandboxHostID    = "aaaaaaaa-0000-0000-0000-000000000001"
	testSandboxHostEpoch = "bbbbbbbb-0000-0000-0000-000000000002"
	testSandboxHostToken = "sandbox-host-test-token-000000000001"
)

func TestSandboxHostWebSocketAuthenticationAndHeartbeat(t *testing.T) {
	server := newSandboxHostTestServer(t)
	httpServer := httptest.NewServer(server.Handler())
	t.Cleanup(httpServer.Close)

	connection := dialSandboxHost(
		t,
		httpServer.URL,
		testSandboxHostID,
		testSandboxHostToken,
	)
	t.Cleanup(func() {
		_ = connection.Close(websocket.StatusNormalClosure, "test complete")
	})
	writeSandboxHostFrame(t, connection, sandboxHostRegistrationFrame(1))
	waitForSandboxHost(t, server, func(snapshot sandboxhost.HostSnapshot) bool {
		return snapshot.LastInbound == 1
	})

	writeSandboxHostFrame(t, connection, sandboxHostHeartbeatFrame(2))
	snapshot := waitForSandboxHost(
		t,
		server,
		func(snapshot sandboxhost.HostSnapshot) bool {
			return snapshot.LastInbound == 2 && snapshot.Heartbeat != nil
		},
	)
	if snapshot.Heartbeat.Mode != "sandbox_dedicated" ||
		snapshot.Heartbeat.AvailableCPU != 8 {
		t.Fatalf("unexpected heartbeat: %+v", snapshot.Heartbeat)
	}

	writeSandboxHostFrame(t, connection, sandboxHostHeartbeatFrame(2))
	readContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, _, err := connection.Read(readContext); err == nil {
		t.Fatal("replayed sandbox host sequence did not close connection")
	}
}

func TestSandboxHostWebSocketRejectsUnauthorizedBeforeUpgrade(t *testing.T) {
	server := newSandboxHostTestServer(t)
	httpServer := httptest.NewServer(server.Handler())
	t.Cleanup(httpServer.Close)
	wsURL := "ws" + strings.TrimPrefix(httpServer.URL, "http") + "/ws/sandbox-host"

	for name, options := range map[string]*websocket.DialOptions{
		"missing headers": nil,
		"wrong token": {
			HTTPHeader: http.Header{
				sandboxhost.HostIDHeader: []string{testSandboxHostID},
				"Authorization": []string{
					"Bearer sandbox-host-test-token-incorrect",
				},
			},
		},
		"wrong host": {
			HTTPHeader: http.Header{
				sandboxhost.HostIDHeader: []string{
					"aaaaaaaa-0000-0000-0000-000000000099",
				},
				"Authorization": []string{"Bearer " + testSandboxHostToken},
			},
		},
	} {
		t.Run(name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			connection, response, err := websocket.Dial(ctx, wsURL, options)
			if connection != nil {
				_ = connection.Close(websocket.StatusNormalClosure, "unexpected")
			}
			if err == nil {
				t.Fatal("unauthorized sandbox host connected")
			}
			if response == nil || response.StatusCode != http.StatusUnauthorized {
				t.Fatalf("response = %#v, error = %v", response, err)
			}
			_ = response.Body.Close()
		})
	}
}

func TestSandboxHostWebSocketRequiresRegistrationIdentity(t *testing.T) {
	server := newSandboxHostTestServer(t)
	httpServer := httptest.NewServer(server.Handler())
	t.Cleanup(httpServer.Close)

	connection := dialSandboxHost(
		t,
		httpServer.URL,
		testSandboxHostID,
		testSandboxHostToken,
	)
	mismatched := sandboxHostRegistrationFrame(1)
	mismatched.HostID = "aaaaaaaa-0000-0000-0000-000000000099"
	writeSandboxHostFrame(t, connection, mismatched)
	readContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, _, err := connection.Read(readContext); err == nil {
		t.Fatal("mismatched sandbox host registration remained connected")
	}
	if len(server.sandboxHosts.Snapshots()) != 0 {
		t.Fatal("mismatched sandbox host was registered")
	}
}

func newSandboxHostTestServer(t *testing.T) *Server {
	t.Helper()
	tokenHash := sha256.Sum256([]byte(testSandboxHostToken))
	logger := slog.New(
		slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}),
	)
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	server := NewServer(
		registry.New(logger),
		st,
		ServerConfig{
			SandboxHostAuth: sandboxhost.AuthConfig{
				TokenSHA256JSON: `{"` + testSandboxHostID + `":"` +
					hex.EncodeToString(tokenHash[:]) + `"}`,
			},
		},
		logger,
	)
	t.Cleanup(server.Close)
	return server
}

func dialSandboxHost(
	t *testing.T,
	baseURL string,
	hostID string,
	token string,
) *websocket.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	connection, _, err := websocket.Dial(
		ctx,
		"ws"+strings.TrimPrefix(baseURL, "http")+"/ws/sandbox-host",
		&websocket.DialOptions{
			HTTPHeader: http.Header{
				sandboxhost.HostIDHeader: []string{hostID},
				"Authorization":          []string{"Bearer " + token},
			},
		},
	)
	if err != nil {
		t.Fatalf("dial sandbox host: %v", err)
	}
	return connection
}

func writeSandboxHostFrame(t *testing.T, connection *websocket.Conn, frame any) {
	t.Helper()
	encoded, err := json.Marshal(frame)
	if err != nil {
		t.Fatalf("marshal sandbox host frame: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := connection.Write(ctx, websocket.MessageText, encoded); err != nil {
		t.Fatalf("write sandbox host frame: %v", err)
	}
}

func sandboxHostRegistrationFrame(
	sequence uint64,
) protocol.SandboxEnvelope[protocol.SandboxHostRegisterPayload] {
	return protocol.SandboxEnvelope[protocol.SandboxHostRegisterPayload]{
		Type:            protocol.SandboxTypeHostRegister,
		ProtocolVersion: protocol.SandboxProtocolVersion,
		HostID:          testSandboxHostID,
		ConnectionEpoch: testSandboxHostEpoch,
		Sequence:        sequence,
		Payload: protocol.SandboxHostRegisterPayload{
			Capabilities: protocol.SandboxHostCapabilities{
				DaemonVersion:       "0.1.0",
				OperatingSystem:     "macos",
				Architecture:        "arm64",
				MachineModel:        "Mac16,1",
				ChipName:            "Apple M4 Pro",
				CPUCount:            12,
				MemoryBytes:         48 * 1024 * 1024 * 1024,
				MaximumSandboxes:    2,
				WorkspaceSizesBytes: []uint64{25 * 1024 * 1024 * 1024},
				SupportsGPU:         true,
			},
		},
	}
}

func sandboxHostHeartbeatFrame(
	sequence uint64,
) protocol.SandboxEnvelope[protocol.SandboxHostHeartbeatPayload] {
	return protocol.SandboxEnvelope[protocol.SandboxHostHeartbeatPayload]{
		Type:            protocol.SandboxTypeHostHeartbeat,
		ProtocolVersion: protocol.SandboxProtocolVersion,
		HostID:          testSandboxHostID,
		ConnectionEpoch: testSandboxHostEpoch,
		Sequence:        sequence,
		Payload: protocol.SandboxHostHeartbeatPayload{
			Mode:            "sandbox_dedicated",
			AvailableCPU:    8,
			AvailableMemory: 32 * 1024 * 1024 * 1024,
			Leases:          []protocol.SandboxHostLeaseObservation{},
		},
	}
}

func waitForSandboxHost(
	t *testing.T,
	server *Server,
	accept func(sandboxhost.HostSnapshot) bool,
) sandboxhost.HostSnapshot {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		snapshots := server.sandboxHosts.Snapshots()
		if len(snapshots) == 1 && accept(snapshots[0]) {
			return snapshots[0]
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("timed out waiting for sandbox host state")
	return sandboxhost.HostSnapshot{}
}
