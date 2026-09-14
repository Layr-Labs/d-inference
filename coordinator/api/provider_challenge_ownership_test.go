package api

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// Each connection must consume only its own outstanding nonce, and a consumed
// nonce must not settle a later challenge. Real socket ordering and recorded
// challenge counts distinguish those outcomes from merely surviving bad input.
func TestProviderChallengeNoncesStayWithTheirConnection(t *testing.T) {
	logger := quietLogger()
	reg := registry.New(logger)
	srv := NewServer(reg, store.NewMemory(store.Config{}), ServerConfig{}, logger)
	srv.SetChallengeInterval(time.Hour)
	t.Cleanup(srv.Close)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	t.Cleanup(cancel)

	write := func(conn *websocket.Conn, message any) {
		t.Helper()
		data, err := json.Marshal(message)
		if err != nil {
			t.Fatal(err)
		}
		if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
			t.Fatalf("write provider frame: %v", err)
		}
	}
	readChallenge := func(conn *websocket.Conn) protocol.AttestationChallengeMessage {
		t.Helper()
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				t.Fatalf("read challenge: %v", err)
			}
			var message protocol.AttestationChallengeMessage
			if err := json.Unmarshal(data, &message); err != nil {
				t.Fatalf("decode coordinator frame: %v", err)
			}
			if message.Type == protocol.TypeAttestationChallenge {
				if message.Nonce == "" || message.Timestamp == "" {
					t.Fatal("challenge omitted nonce or timestamp")
				}
				return message
			}
		}
	}
	connect := func(model, key string) (*websocket.Conn, *registry.Provider, protocol.AttestationChallengeMessage) {
		t.Helper()
		conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(ts.URL, "http")+"/ws/provider", nil)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = conn.CloseNow() })
		write(conn, protocol.RegisterMessage{
			Type: protocol.TypeRegister, Backend: registry.BackendMLXSwift,
			Hardware:  protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
			Models:    []protocol.ModelInfo{{ID: model, ModelType: "chat"}},
			PublicKey: key, Attestation: createTestAttestationJSON(t, key),
		})
		challenge := readChallenge(conn)
		provider := findProviderByModel(reg, model)
		if provider == nil {
			t.Fatal("challenge arrived without the registered provider")
		}
		return conn, provider, challenge
	}
	response := func(challenge protocol.AttestationChallengeMessage, key, model, hash string) protocol.AttestationResponseMessage {
		t.Helper()
		yes := true
		message := protocol.AttestationResponseMessage{
			Type: protocol.TypeAttestationResponse, Nonce: challenge.Nonce,
			PublicKey: key, Signature: testChallengeSignature(challenge.Nonce, challenge.Timestamp, key),
			SIPEnabled: &yes, SecureBootEnabled: &yes, RDMADisabled: &yes,
			ModelHashes: map[string]string{model: hash},
		}
		message.StatusSignature = testStatusSignature(t, attestation.StatusCanonicalInput{
			Nonce: challenge.Nonce, Timestamp: challenge.Timestamp,
			SIPEnabled: message.SIPEnabled, SecureBootEnabled: message.SecureBootEnabled,
			RDMADisabled: message.RDMADisabled, ModelHashes: message.ModelHashes,
		}, key)
		return message
	}
	// A heartbeat sent after an invalid reply on the same socket proves the
	// read loop has already delivered that reply before another socket responds.
	barrier := func(conn *websocket.Conn, provider *registry.Provider) {
		t.Helper()
		provider.Mu().Lock()
		before := provider.LastHeartbeat
		provider.Mu().Unlock()
		write(conn, protocol.HeartbeatMessage{Type: protocol.TypeHeartbeat, Status: "online"})
		if !waitForCond(2*time.Second, func() bool {
			provider.Mu().Lock()
			defer provider.Mu().Unlock()
			return provider.LastHeartbeat.After(before)
		}) {
			t.Fatal("heartbeat did not follow the challenge reply")
		}
	}
	assertProof := func(provider *registry.Provider, hash string, passes int) {
		t.Helper()
		if !waitForCond(2*time.Second, func() bool {
			provider.Mu().Lock()
			defer provider.Mu().Unlock()
			return len(provider.Models) == 1 && provider.Models[0].WeightHash == hash &&
				provider.Reputation.ChallengesPassed >= passes
		}) {
			t.Fatal("the connection's current challenge did not publish its verified model hash")
		}
		provider.Mu().Lock()
		defer provider.Mu().Unlock()
		if provider.Reputation.ChallengesPassed != passes || provider.Reputation.ChallengesFailed != 0 {
			t.Fatalf("challenge counts = %d passed / %d failed, want %d / 0",
				provider.Reputation.ChallengesPassed, provider.Reputation.ChallengesFailed, passes)
		}
	}

	const modelA, modelB = "nonce-owner-a", "nonce-owner-b"
	keyA, keyB := testPublicKeyB64(), testPublicKeyB64()
	connA, providerA, challengeA := connect(modelA, keyA)
	connB, providerB, challengeB := connect(modelB, keyB)
	if challengeA.Nonce == challengeB.Nonce {
		t.Fatal("connections received the same nonce")
	}
	hashA, hashB := strings.Repeat("a", 64), strings.Repeat("b", 64)

	// B answers A's nonce with B's genuine key. This must not consume A's
	// pending challenge or turn B's answer into a failure on A's connection.
	write(connB, response(challengeA, keyB, modelB, hashB))
	barrier(connB, providerB)
	firstA := response(challengeA, keyA, modelA, hashA)
	write(connA, firstA)
	write(connB, response(challengeB, keyB, modelB, hashB))
	assertProof(providerA, hashA, 1)
	assertProof(providerB, hashB, 1)

	providerA.RequestImmediateChallenge()
	nextA := readChallenge(connA)
	if nextA.Nonce == challengeA.Nonce {
		t.Fatal("immediate challenge reused the consumed nonce")
	}
	write(connA, firstA)
	barrier(connA, providerA)
	nextHash := strings.Repeat("c", 64)
	write(connA, response(nextA, keyA, modelA, nextHash))
	// The unique new hash proves the new response was processed; exactly two
	// recorded passes proves replay did not add another accepted challenge.
	assertProof(providerA, nextHash, 2)
	assertProof(providerB, hashB, 1)
}
