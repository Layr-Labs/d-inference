package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/sandboxhost"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
	"nhooyr.io/websocket"
)

func TestSandboxAPILifecycleOverAuthenticatedHostWebSocket(t *testing.T) {
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
	writeSandboxHostFrame(t, connection, sandboxHostHeartbeatFrame(2))
	waitForSandboxHost(t, server, func(snapshot sandboxhost.HostSnapshot) bool {
		return snapshot.Heartbeat != nil
	})

	createResponse := doSandboxAPIRequest(
		t,
		http.MethodPost,
		httpServer.URL+"/v1/sandboxes",
		`{
			"base_image_id":"macos-tahoe-v1",
			"cpu_count":4,
			"memory_gib":8,
			"workspace_gib":25,
			"gpu":false
		}`,
	)
	if createResponse.StatusCode != http.StatusAccepted {
		t.Fatalf(
			"create status = %d body=%s",
			createResponse.StatusCode,
			createResponse.Body,
		)
	}
	var created sandboxOperationResponse
	decodeSandboxAPIResponse(t, createResponse.Body, &created)
	if created.Sandbox == nil || created.Operation == nil {
		t.Fatalf("incomplete create response: %+v", created)
	}
	prepare := readSandboxCoordinatorMessage(t, connection)
	preparePayload, ok := prepare.Payload.(*protocol.SandboxPreparePayload)
	if !ok ||
		preparePayload.OperationID != created.Operation.ID ||
		preparePayload.Scope.SandboxID != created.Sandbox.ID {
		t.Fatalf("unexpected prepare payload: %#v", prepare.Payload)
	}
	writeSandboxHostFrame(
		t,
		connection,
		hostOperationStateFrame(
			3,
			preparePayload.OperationID,
			preparePayload.Scope,
			store.SandboxOperationKindPrepare,
			protocol.SandboxOperationReady,
		),
	)
	waitForSandboxAPIState(
		t,
		httpServer.URL,
		created.Sandbox.ID,
		store.SandboxStateReady,
	)

	idempotencyKey := uuid.NewString()
	commandResponse := doSandboxAPIRequest(
		t,
		http.MethodPost,
		fmt.Sprintf(
			"%s/v1/sandboxes/%s/commands",
			httpServer.URL,
			created.Sandbox.ID,
		),
		fmt.Sprintf(
			`{"idempotency_key":%q,"arguments":["/usr/bin/printf","hello"],"timeout_seconds":900}`,
			idempotencyKey,
		),
	)
	if commandResponse.StatusCode != http.StatusAccepted {
		t.Fatalf(
			"command status = %d body=%s",
			commandResponse.StatusCode,
			commandResponse.Body,
		)
	}
	var commandAccepted sandboxCommandResponse
	decodeSandboxAPIResponse(t, commandResponse.Body, &commandAccepted)
	commandMessage := readSandboxCoordinatorMessage(t, connection)
	commandPayload, ok := commandMessage.Payload.(*protocol.SandboxCommandPayload)
	if !ok ||
		commandPayload.CommandID != commandAccepted.Command.ID ||
		commandPayload.IdempotencyKey != idempotencyKey {
		t.Fatalf("unexpected command payload: %#v", commandMessage.Payload)
	}
	stdout := "hello"
	exitCode := int32(0)
	writeSandboxHostFrame(
		t,
		connection,
		protocol.SandboxEnvelope[protocol.SandboxCommandStatePayload]{
			Type:            protocol.SandboxTypeCommandState,
			ProtocolVersion: protocol.SandboxProtocolVersion,
			HostID:          testSandboxHostID,
			ConnectionEpoch: testSandboxHostEpoch,
			Sequence:        4,
			Payload: protocol.SandboxCommandStatePayload{
				CommandID:       commandPayload.CommandID,
				Scope:           commandPayload.Scope,
				State:           protocol.SandboxCommandSucceeded,
				ExitCode:        &exitCode,
				StandardOutput:  &stdout,
				OutputTruncated: false,
			},
		},
	)
	completed := waitForSandboxCommand(
		t,
		httpServer.URL,
		created.Sandbox.ID,
		commandPayload.CommandID,
	)
	if completed.State != store.SandboxCommandSucceeded ||
		completed.StandardOutput != "hello" ||
		completed.ExitCode == nil ||
		*completed.ExitCode != 0 {
		t.Fatalf("unexpected command result: %+v", completed)
	}

	deleteResponse := doSandboxAPIRequest(
		t,
		http.MethodDelete,
		fmt.Sprintf("%s/v1/sandboxes/%s", httpServer.URL, created.Sandbox.ID),
		"",
	)
	if deleteResponse.StatusCode != http.StatusAccepted {
		t.Fatalf(
			"terminate status = %d body=%s",
			deleteResponse.StatusCode,
			deleteResponse.Body,
		)
	}
	stop := readSandboxCoordinatorMessage(t, connection)
	stopPayload, ok := stop.Payload.(*protocol.SandboxOperationPayload)
	if !ok || stop.Header.Type != protocol.SandboxTypeStop {
		t.Fatalf("unexpected stop payload: %#v", stop)
	}
	writeSandboxHostFrame(
		t,
		connection,
		hostOperationStateFrame(
			5,
			stopPayload.OperationID,
			stopPayload.Scope,
			store.SandboxOperationKindStop,
			protocol.SandboxOperationStopped,
		),
	)
	deletion := readSandboxCoordinatorMessage(t, connection)
	deletePayload, ok := deletion.Payload.(*protocol.SandboxOperationPayload)
	if !ok || deletion.Header.Type != protocol.SandboxTypeDelete {
		t.Fatalf("unexpected delete payload: %#v", deletion)
	}
	writeSandboxHostFrame(
		t,
		connection,
		hostOperationStateFrame(
			6,
			deletePayload.OperationID,
			deletePayload.Scope,
			store.SandboxOperationKindDelete,
			protocol.SandboxOperationDeleted,
		),
	)
	deleted := waitForSandboxAPIState(
		t,
		httpServer.URL,
		created.Sandbox.ID,
		store.SandboxStateDeleted,
	)
	if !deleted.TerminationRequested {
		t.Fatal("terminated sandbox lost durable termination intent")
	}
}

type sandboxHTTPResponse struct {
	StatusCode int
	Body       []byte
}

func doSandboxAPIRequest(
	t *testing.T,
	method string,
	url string,
	body string,
) sandboxHTTPResponse {
	t.Helper()
	request, err := http.NewRequest(method, url, bytes.NewBufferString(body))
	if err != nil {
		t.Fatalf("create request: %v", err)
	}
	request.Header.Set("Authorization", "Bearer test-key")
	if body != "" {
		request.Header.Set("Content-Type", "application/json")
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("%s %s: %v", method, url, err)
	}
	defer response.Body.Close()
	encoded, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatalf("read response: %v", err)
	}
	return sandboxHTTPResponse{
		StatusCode: response.StatusCode,
		Body:       encoded,
	}
}

func decodeSandboxAPIResponse(t *testing.T, encoded []byte, target any) {
	t.Helper()
	if err := json.Unmarshal(encoded, target); err != nil {
		t.Fatalf("decode API response %s: %v", encoded, err)
	}
}

func readSandboxCoordinatorMessage(
	t *testing.T,
	connection *websocket.Conn,
) protocol.SandboxDecodedMessage {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	messageType, encoded, err := connection.Read(ctx)
	if err != nil {
		t.Fatalf("read coordinator frame: %v", err)
	}
	if messageType != websocket.MessageText {
		t.Fatalf("coordinator message type = %v", messageType)
	}
	message, err := protocol.DecodeSandboxCoordinatorMessage(encoded)
	if err != nil {
		t.Fatalf("decode coordinator frame %s: %v", encoded, err)
	}
	return message
}

func hostOperationStateFrame(
	sequence uint64,
	operationID string,
	scope protocol.SandboxScope,
	operation string,
	state string,
) protocol.SandboxEnvelope[protocol.SandboxOperationStatePayload] {
	return protocol.SandboxEnvelope[protocol.SandboxOperationStatePayload]{
		Type:            protocol.SandboxTypeOperationState,
		ProtocolVersion: protocol.SandboxProtocolVersion,
		HostID:          testSandboxHostID,
		ConnectionEpoch: testSandboxHostEpoch,
		Sequence:        sequence,
		Payload: protocol.SandboxOperationStatePayload{
			OperationID: operationID,
			Scope:       scope,
			Operation:   operation,
			State:       state,
		},
	}
}

func waitForSandboxAPIState(
	t *testing.T,
	baseURL string,
	sandboxID string,
	state string,
) *store.SandboxRecord {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		response := doSandboxAPIRequest(
			t,
			http.MethodGet,
			fmt.Sprintf("%s/v1/sandboxes/%s", baseURL, sandboxID),
			"",
		)
		if response.StatusCode == http.StatusOK {
			var sandbox store.SandboxRecord
			decodeSandboxAPIResponse(t, response.Body, &sandbox)
			if sandbox.State == state {
				return &sandbox
			}
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("timed out waiting for sandbox %s state %s", sandboxID, state)
	return nil
}

func waitForSandboxCommand(
	t *testing.T,
	baseURL string,
	sandboxID string,
	commandID string,
) *store.SandboxCommand {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		response := doSandboxAPIRequest(
			t,
			http.MethodGet,
			fmt.Sprintf(
				"%s/v1/sandboxes/%s/commands/%s",
				baseURL,
				sandboxID,
				commandID,
			),
			"",
		)
		if response.StatusCode == http.StatusOK {
			var wrapped sandboxCommandResponse
			decodeSandboxAPIResponse(t, response.Body, &wrapped)
			if wrapped.Command.Terminal() {
				return wrapped.Command
			}
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("timed out waiting for sandbox command %s", commandID)
	return nil
}
