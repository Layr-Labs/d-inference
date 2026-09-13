package api

import (
	"context"
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

func TestSandboxAPIStartOverAuthenticatedHostWebSocket(t *testing.T) {
	server := newSandboxHostTestServer(t)
	ready, _ := seedSandboxAPIResource(t, server.store, false)
	stop, err := server.sandboxes.Stop(context.Background(), ready.AccountID, ready.ID, uuid.NewString())
	if err != nil {
		t.Fatal(err)
	}
	stopped, _, err := server.store.ApplySandboxOperationUpdate(context.Background(), store.SandboxOperationUpdate{OperationID: stop.ID, SandboxID: ready.ID,
		Generation: ready.Generation, FencingToken: ready.FencingToken, State: store.SandboxOperationStopped, UpdatedAt: time.Now().UTC()})
	if err != nil {
		t.Fatal(err)
	}
	httpServer := httptest.NewServer(server.Handler())
	t.Cleanup(httpServer.Close)
	connection := dialSandboxHost(t, httpServer.URL, testSandboxHostID, testSandboxHostToken)
	t.Cleanup(func() { _ = connection.Close(websocket.StatusNormalClosure, "test complete") })
	registration := sandboxHostRegistrationFrame(1)
	registration.Payload.Capabilities.SupportsStart = true
	writeSandboxHostFrame(t, connection, registration)
	waitForSandboxHost(t, server, func(snapshot sandboxhost.HostSnapshot) bool { return snapshot.LastInbound == 1 })
	key := uuid.NewString()
	response := doSandboxAPIRequestWithIdempotency(t, http.MethodPost, httpServer.URL+"/v1/sandboxes/"+ready.ID+"/start", "", key)
	if response.StatusCode != http.StatusAccepted {
		t.Fatalf("start status=%d body=%s", response.StatusCode, response.Body)
	}
	var accepted sandboxOperationResponse
	decodeSandboxAPIResponse(t, response.Body, &accepted)
	message := readSandboxCoordinatorMessage(t, connection)
	start, ok := message.Payload.(*protocol.SandboxStartPayload)
	if !ok || start.Scope.FencingToken != stopped.FencingToken || start.RequestedFencingToken <= stopped.FencingToken || accepted.Operation.ID != start.OperationID {
		t.Fatalf("start frame: %+v accepted=%+v", message, accepted)
	}
	scope := start.Scope
	scope.FencingToken = start.RequestedFencingToken
	writeSandboxHostFrame(t, connection, hostOperationStateFrame(2, start.OperationID, scope, store.SandboxOperationKindStart, store.SandboxOperationBooting))
	writeSandboxHostFrame(t, connection, hostOperationStateFrame(3, start.OperationID, scope, store.SandboxOperationKindStart, store.SandboxOperationReady))
	resumed := waitForSandboxAPIState(t, httpServer.URL, ready.ID, store.SandboxStateReady)
	if resumed.FencingToken != scope.FencingToken || !resumed.LeaseExpiresAt.Equal(stopped.LeaseExpiresAt) {
		t.Fatalf("resume changed allocation: %+v", resumed)
	}
	replay := doSandboxAPIRequestWithIdempotency(t, http.MethodPost, httpServer.URL+"/v1/sandboxes/"+ready.ID+"/start", "", key)
	if replay.StatusCode != http.StatusAccepted {
		t.Fatalf("replay status=%d body=%s", replay.StatusCode, replay.Body)
	}
	var repeated sandboxOperationResponse
	decodeSandboxAPIResponse(t, replay.Body, &repeated)
	if repeated.Operation.ID != start.OperationID || repeated.Operation.State != store.SandboxOperationReady {
		t.Fatalf("start replay: %+v", repeated)
	}
}

func TestSandboxAPIStartUsesNewWorkAdmission(t *testing.T) {
	for name, config := range map[string]SandboxServiceConfig{
		"paused":     {Enabled: true},
		"unenrolled": {Enabled: true, AdmissionEnabled: true, AllowedAccountIDs: []string{"other-account"}},
	} {
		t.Run(name, func(t *testing.T) {
			server := newSandboxHostTestServer(t, func(c *ServerConfig) { c.SandboxService = config })
			sandbox, _ := seedSandboxAPIResource(t, server.store, false)
			response := sandboxLocalAPIRequest(server, http.MethodPost, "/v1/sandboxes/"+sandbox.ID+"/start", "test-key")
			want := http.StatusForbidden
			if name == "paused" {
				want = http.StatusServiceUnavailable
			}
			if response.Code != want {
				t.Fatalf("start admission status=%d body=%s", response.Code, response.Body.String())
			}
		})
	}
}
