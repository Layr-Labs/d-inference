package provider_test

// A control-only cluster member waits for cluster_member_accepted and ends its
// control loop when the coordinator never sends it. These tests drive real
// provider WebSocket sessions through the production read loop and assert the
// acknowledgement on the wire: exactly once, only for a registration the
// coordinator kept in the member role, with the fields the provider decodes.

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"nhooyr.io/websocket"
)

const clusterMemberFixtureModel = "cluster-member-fixture-model"

// clusterMemberAcceptedWire mirrors the provider's decoder
// (ClusterMemberAccepted in ProviderExecutionRole.swift plus the `type`
// discriminator): every key is required and no other key is tolerated here.
type clusterMemberAcceptedWire struct {
	Type                    *string `json:"type"`
	ExecutionRole           *string `json:"execution_role"`
	MemberRegistrationNonce *string `json:"member_registration_nonce"`
	ProviderID              *string `json:"provider_id"`
}

type clusterMemberSession struct {
	owner    *Owner
	registry *registry.Registry
	conn     *websocket.Conn
}

// dialProviderSession serves the production provider handler from a real
// in-process HTTP server (TLS when asked) and dials one provider socket.
func dialProviderSession(t *testing.T, ctx context.Context, nativePairs func(*registry.Registry) *registry.NativePairCoordinator, secured bool) clusterMemberSession {
	t.Helper()
	logger := quietLogger()
	reg := registry.New(logger)
	reg.SetModelCatalog([]registry.CatalogEntry{{ID: clusterMemberFixtureModel}})
	dependencies := Dependencies{Registry: reg, Store: memory.NewMemory(store.Config{AdminKey: "test-key"}), Logger: logger}
	if nativePairs != nil {
		dependencies.NativePairs = nativePairs(reg)
		if dependencies.NativePairs == nil {
			t.Fatal("approved catalog did not construct the native pair coordinator")
		}
		t.Cleanup(dependencies.NativePairs.Close)
	}
	owner := newProviderFixture(t, dependencies)
	handler := http.HandlerFunc(owner.HandleProviderWS)
	var server *httptest.Server
	var options *websocket.DialOptions
	if secured {
		server = httptest.NewTLSServer(handler)
		options = &websocket.DialOptions{HTTPClient: server.Client()}
	} else {
		server = httptest.NewServer(handler)
	}
	t.Cleanup(server.Close)
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(server.URL, "http")+"/ws/provider", options)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	t.Cleanup(func() { _ = conn.CloseNow() })
	return clusterMemberSession{owner: owner, registry: reg, conn: conn}
}

func approvedNativePairs(t *testing.T) func(*registry.Registry) *registry.NativePairCoordinator {
	t.Helper()
	hash := sha256.Sum256([]byte("cluster-member-accept-fixture"))
	catalog, err := registry.NewNativeRuntimeCatalog([]registry.NativeRuntimeApproval{{
		ID: "fixture", Model: clusterMemberFixtureModel, Generation: 1, PlanSHA256: hash,
		ArtifactSHA256: hash, NativeRuntimeSHA256: hash, MetallibSHA256: hash,
		ResourceLibrarySHA256: hash, CapabilitySHA256: hash, ResourcePolicySHA256: hash,
		ProfileSHA256: hash, Schedule: 1, MaximumTransportFrame: 4136, MaximumPlaintext: 4096,
		MaximumRecords: 64, MaximumCumulativePlaintext: 262144,
		AllowedChips: []string{"Apple M3 Max"}, NotAfter: time.Now().Add(time.Hour)}})
	if err != nil {
		t.Fatal(err)
	}
	return func(r *registry.Registry) *registry.NativePairCoordinator {
		return registry.NewNativePairCoordinator(r, catalog)
	}
}

func memberRegistration(nonce string) protocol.RegisterMessage {
	return protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		ExecutionRole:           protocol.ExecutionRoleClusterMember,
		MemberRegistrationNonce: nonce,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{},
		ClusterModels:           []protocol.ModelInfo{{ID: clusterMemberFixtureModel, ModelType: "chat", Quantization: "4bit"}},
		Backend:                 registry.BackendMLXSwift,
	}
}

func soloRegistration() protocol.RegisterMessage {
	return protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: clusterMemberFixtureModel, ModelType: "chat", Quantization: "4bit"}},
		Backend:  registry.BackendMLXSwift,
	}
}

func writeProviderFrame(t *testing.T, ctx context.Context, conn *websocket.Conn, frame any) {
	t.Helper()
	data, err := json.Marshal(frame)
	if err != nil {
		t.Fatal(err)
	}
	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
		t.Fatalf("write provider frame: %v", err)
	}
}

func frameType(t *testing.T, frame []byte) string {
	t.Helper()
	var envelope struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(frame, &envelope); err != nil {
		t.Fatalf("coordinator frame is not a JSON object: %v", err)
	}
	return envelope.Type
}

// readFramesThrough returns every coordinator frame up to and including the
// first one of the wanted type.
func readFramesThrough(t *testing.T, ctx context.Context, conn *websocket.Conn, wanted string) [][]byte {
	t.Helper()
	var frames [][]byte
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			t.Fatalf("socket ended before %s (read %d frames): %v", wanted, len(frames), err)
		}
		frames = append(frames, data)
		if frameType(t, data) == wanted {
			return frames
		}
	}
}

// readFramesUntilClosed returns every coordinator frame the socket carried and
// the close status that ended it.
func readFramesUntilClosed(t *testing.T, ctx context.Context, conn *websocket.Conn) ([][]byte, websocket.StatusCode) {
	t.Helper()
	var frames [][]byte
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			if ctx.Err() != nil {
				t.Fatalf("coordinator kept the refused connection open (read %d frames): %v", len(frames), err)
			}
			return frames, websocket.CloseStatus(err)
		}
		frames = append(frames, data)
	}
}

func acknowledgements(t *testing.T, frames [][]byte) [][]byte {
	t.Helper()
	var found [][]byte
	for _, frame := range frames {
		if frameType(t, frame) == protocol.TypeClusterMemberAccepted {
			found = append(found, frame)
		}
	}
	return found
}

// drainBarrier is answered on the same FIFO control lane that carries the
// acknowledgement, after the read loop finished the whole register case. Its
// acknowledgement therefore bounds "everything registration sent" without a
// timing assumption.
func framesThroughDrainBarrier(t *testing.T, ctx context.Context, conn *websocket.Conn) [][]byte {
	t.Helper()
	writeProviderFrame(t, ctx, conn, protocol.ProviderDrainMessage{Type: protocol.TypeProviderDrain, RequestID: "registration-barrier"})
	return readFramesThrough(t, ctx, conn, protocol.TypeProviderDrainAck)
}

func requireAcknowledgement(t *testing.T, frame []byte, nonce, providerID string) {
	t.Helper()
	want := fmt.Sprintf(`{"type":"cluster_member_accepted","execution_role":"cluster_member","member_registration_nonce":%q,"provider_id":%q}`, nonce, providerID)
	if string(frame) != want {
		t.Fatalf("acknowledgement wire shape\n got: %s\nwant: %s", frame, want)
	}
	var decoded clusterMemberAcceptedWire
	decoder := json.NewDecoder(bytes.NewReader(frame))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&decoded); err != nil {
		t.Fatalf("acknowledgement carries a key the provider type does not define: %v", err)
	}
	if decoded.Type == nil || decoded.ExecutionRole == nil || decoded.MemberRegistrationNonce == nil || decoded.ProviderID == nil {
		t.Fatalf("acknowledgement omits a key the provider decoder requires: %s", frame)
	}
	// ClusterMemberNegotiation.accept: nonempty provider ID of at most 128 UTF-8 bytes.
	if id := *decoded.ProviderID; id == "" || len(id) > 128 {
		t.Fatalf("provider_id %q is outside the provider's accepted bound", id)
	}
}

func TestClusterMemberRegistrationIsAcknowledgedOncePerConnection(t *testing.T) {
	cases := []struct {
		name        string
		nativePairs bool
		secured     bool
	}{
		// Production default: no approved native runtime catalog. The role is
		// still accepted; only native pair control stays disabled.
		{name: "native pair control disabled"},
		// With native pair control enabled the member attaches over the actual
		// TLS connection first, then is acknowledged.
		{name: "native pair control attached over TLS", nativePairs: true, secured: true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			var nativePairs func(*registry.Registry) *registry.NativePairCoordinator
			if c.nativePairs {
				nativePairs = approvedNativePairs(t)
			}
			session := dialProviderSession(t, ctx, nativePairs, c.secured)
			nonce := strings.Repeat("0123456789abcdef", 4)
			writeProviderFrame(t, ctx, session.conn, memberRegistration(nonce))

			frames := readFramesThrough(t, ctx, session.conn, protocol.TypeClusterMemberAccepted)
			ids := session.registry.ProviderIDs()
			if len(ids) != 1 {
				t.Fatalf("acknowledged member is not the single registered connection: %v", ids)
			}
			requireAcknowledgement(t, frames[len(frames)-1], nonce, ids[0])

			// Exactly one acknowledgement per negotiation: the provider treats
			// a second one as a failed negotiation and ends its control loop.
			if extra := acknowledgements(t, framesThroughDrainBarrier(t, ctx, session.conn)); len(extra) != 0 {
				t.Fatalf("member connection acknowledged again: %s", extra[0])
			}
		})
	}
}

func TestSoloRegistrationReceivesNoClusterMemberAcknowledgement(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	session := dialProviderSession(t, ctx, nil, false)
	writeProviderFrame(t, ctx, session.conn, soloRegistration())

	frames := framesThroughDrainBarrier(t, ctx, session.conn)
	if len(session.registry.ProviderIDs()) != 1 {
		t.Fatal("solo registration was not accepted")
	}
	if found := acknowledgements(t, frames); len(found) != 0 {
		t.Fatalf("solo connection received a member acknowledgement: %s", found[0])
	}
}

func TestRefusedClusterMemberRegistrationReceivesNoAcknowledgement(t *testing.T) {
	nonce := strings.Repeat("fedcba9876543210", 4)

	// Native pair control is enabled but this member did not arrive over an
	// actual TLS connection, so the coordinator refuses the member transport
	// after the registry created the connection. Nothing may tell the provider
	// its role was accepted on a connection that is being closed.
	//
	// The refusal closes the socket at once, so an acknowledgement queued too
	// early only sometimes reaches the wire ahead of the close frame. Repeated
	// sessions make that misordering all but certain to surface; correct
	// ordering passes every one of them.
	t.Run("member transport refused", func(t *testing.T) {
		nativePairs := approvedNativePairs(t)
		for attempt := 0; attempt < 32; attempt++ {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			session := dialProviderSession(t, ctx, nativePairs, false)
			writeProviderFrame(t, ctx, session.conn, memberRegistration(nonce))

			frames, status := readFramesUntilClosed(t, ctx, session.conn)
			cancel()
			if status != websocket.StatusPolicyViolation {
				t.Fatalf("refused member transport closed with %d, want policy violation", status)
			}
			if found := acknowledgements(t, frames); len(found) != 0 {
				t.Fatalf("refused member received an acknowledgement: %s", found[0])
			}
		}
	})

	// The register frame is rejected before the registry sees it: a member
	// must publish an empty ordinary inventory.
	t.Run("member role fields malformed", func(t *testing.T) {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		session := dialProviderSession(t, ctx, nil, false)
		malformed := memberRegistration(nonce)
		malformed.Models = malformed.ClusterModels
		writeProviderFrame(t, ctx, session.conn, malformed)
		// An unregistered connection's drain barrier is a policy violation, so
		// the close bounds everything the rejected registration could send.
		writeProviderFrame(t, ctx, session.conn, protocol.ProviderDrainMessage{Type: protocol.TypeProviderDrain, RequestID: "registration-barrier"})

		frames, status := readFramesUntilClosed(t, ctx, session.conn)
		if status != websocket.StatusPolicyViolation {
			t.Fatalf("unregistered drain closed with %d, want policy violation", status)
		}
		if ids := session.registry.ProviderIDs(); len(ids) != 0 {
			t.Fatalf("malformed member registration reached the registry: %v", ids)
		}
		if found := acknowledgements(t, frames); len(found) != 0 {
			t.Fatalf("malformed member received an acknowledgement: %s", found[0])
		}
	})

	t.Run("member version oversized", func(t *testing.T) {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		session := dialProviderSession(t, ctx, nil, false)
		oversized := memberRegistration(nonce)
		oversized.Version = strings.Repeat("9", 129)
		writeProviderFrame(t, ctx, session.conn, oversized)

		frames, status := readFramesUntilClosed(t, ctx, session.conn)
		if status != websocket.StatusPolicyViolation {
			t.Fatalf("oversized version closed with %d, want policy violation", status)
		}
		if found := acknowledgements(t, frames); len(found) != 0 {
			t.Fatalf("refused member received an acknowledgement: %s", found[0])
		}
	})
}
