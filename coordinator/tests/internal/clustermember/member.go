// Package clustermember is a fake control-only cluster member for external
// tests. It speaks the real provider protocol over a real WebSocket: it
// registers in the member role with a cluster membership, sends heartbeats,
// exchanges Secure-Enclave-style signed native-pair control frames and, as a
// pair's leader, answers an ordinary inference request encrypted to its
// registered key.
//
// It does not obtain trust the way a real Mac does. GrantPairTrust fabricates
// the hardware, code and release evidence through the registry's public
// setters, exactly as the registry pair fixtures do; tests that use it prove
// control flow, never hardware trust.
package clustermember

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"golang.org/x/crypto/nacl/box"
	"nhooyr.io/websocket"
)

// ReleasePolicyGeneration is the release generation the fabricated evidence is
// bound to; the registry under test must be set to it.
const ReleasePolicyGeneration = 7

// Options describes one member connection.
type Options struct {
	// ServerURL is the http(s) base URL of the coordinator under test.
	ServerURL string
	// HTTPClient carries the TLS trust of an httptest TLS server; nil dials plain.
	HTTPClient *http.Client
	// Header is sent with the WebSocket upgrade request.
	Header http.Header
	// AuthToken links the connection to an account; empty leaves it unlinked.
	AuthToken string
	Serial    string
	ChipName  string
	Model     string
	// Membership is the registered cluster claim; nil registers none.
	Membership *protocol.ClusterMembership
}

// Member is one registered member connection and the keys it signs with.
type Member struct {
	Conn    *websocket.Conn
	Options Options
	Nonce   string
	// ProcessKey is the registered X25519 public key (base64).
	ProcessKey string
	process    e2e.SessionKeys
	se         *ecdsa.PrivateKey
	sent       uint64
}

// Dial opens the provider socket and registers as a cluster member.
func Dial(t testing.TB, ctx context.Context, options Options) *Member {
	t.Helper()
	m := New(t, options)
	m.Connect(t, ctx)
	return m
}

// New creates a member with its keys and nonce but no connection yet, for a
// test that must know the member's identity before it registers.
func New(t testing.TB, options Options) *Member {
	t.Helper()
	se, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	nonce := make([]byte, 32)
	if _, err = rand.Read(nonce); err != nil {
		t.Fatal(err)
	}
	public, private, err := box.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return &Member{Options: options, Nonce: hex.EncodeToString(nonce),
		ProcessKey: base64.StdEncoding.EncodeToString(public[:]),
		process:    e2e.SessionKeys{PublicKey: *public, PrivateKey: *private}, se: se}
}

// Connect opens the provider socket and sends the member registration.
func (m *Member) Connect(t testing.TB, ctx context.Context) {
	t.Helper()
	var dial *websocket.DialOptions
	if m.Options.HTTPClient != nil || m.Options.Header != nil {
		dial = &websocket.DialOptions{HTTPClient: m.Options.HTTPClient, HTTPHeader: m.Options.Header}
	}
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(m.Options.ServerURL, "http")+"/ws/provider", dial)
	if err != nil {
		t.Fatalf("member websocket dial: %v", err)
	}
	m.Conn = conn
	t.Cleanup(func() { _ = conn.CloseNow() })
	m.write(t, ctx, m.Registration())
}

// Registration is the member-role register frame this member sends.
func (m *Member) Registration() protocol.RegisterMessage {
	return protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		ExecutionRole:           protocol.ExecutionRoleClusterMember,
		MemberRegistrationNonce: m.Nonce,
		ClusterMembership:       m.Options.Membership,
		Models:                  []protocol.ModelInfo{},
		ClusterModels:           []protocol.ModelInfo{{ID: m.Options.Model, ModelType: "chat", Quantization: "4bit"}},
		Hardware:                protocol.Hardware{ChipName: m.Options.ChipName, MemoryGB: 64},
		Backend:                 registry.BackendMLXSwift,
		Version:                 "0.9.2",
		PublicKey:               m.ProcessKey,
		EncryptedResponseChunks: true,
		AuthToken:               m.Options.AuthToken,
		PrivacyCapabilities: &protocol.PrivacyCapabilities{
			TextBackendInprocess: true, TextProxyDisabled: true, SIPEnabled: true,
			AntiDebugEnabled: true, CoreDumpsDisabled: true, EnvScrubbed: true,
		},
	}
}

func (m *Member) write(t testing.TB, ctx context.Context, frame any) {
	t.Helper()
	data, err := json.Marshal(frame)
	if err != nil {
		t.Fatal(err)
	}
	if err = m.Conn.Write(ctx, websocket.MessageText, data); err != nil {
		t.Fatalf("member write: %v", err)
	}
}

// Heartbeat reports a member holding no model, as the provider's control-only
// mode does: the empty authoritative capacity, and status "draining" because
// the member refuses solo work for as long as it runs.
func (m *Member) Heartbeat(t testing.TB, ctx context.Context) {
	t.Helper()
	m.write(t, ctx, protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: protocol.HeartbeatStatusDraining,
		SystemMetrics:   protocol.SystemMetrics{MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal"},
		BackendCapacity: &protocol.BackendCapacity{TotalMemoryGB: 64, Slots: []protocol.BackendSlotCapacity{}},
	})
}

// HeartbeatServing is the heartbeat a leader sends once both ranks are ready:
// it no longer reports draining, and it publishes exactly one loaded slot for
// the pair model with a concurrency of one.
func (m *Member) HeartbeatServing(t testing.TB, ctx context.Context) {
	t.Helper()
	m.write(t, ctx, protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "idle",
		SystemMetrics: protocol.SystemMetrics{MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal"},
		BackendCapacity: &protocol.BackendCapacity{TotalMemoryGB: 64, Slots: []protocol.BackendSlotCapacity{
			{Model: m.Options.Model, State: "idle", MaxConcurrency: 1}}},
	})
}

// ReadInferenceRequest skips other frames and returns the next ordinary
// inference request, with its body decrypted with this member's process key.
func (m *Member) ReadInferenceRequest(t testing.TB, ctx context.Context) (protocol.InferenceRequestMessage, []byte) {
	t.Helper()
	for {
		frame, ok := m.Next(ctx)
		if !ok {
			t.Fatal("member socket ended before an inference request")
		}
		if frame.Type != protocol.TypeInferenceRequest {
			continue
		}
		var request protocol.InferenceRequestMessage
		if err := json.Unmarshal(frame.Data, &request); err != nil || request.EncryptedBody == nil {
			t.Fatalf("coordinator sent a malformed inference request: %v", err)
		}
		body, err := e2e.DecryptWithPrivateKey(&e2e.EncryptedPayload{
			EphemeralPublicKey: request.EncryptedBody.EphemeralPublicKey,
			Ciphertext:         request.EncryptedBody.Ciphertext}, m.process.PrivateKey)
		if err != nil {
			t.Fatalf("inference request is not encrypted to this member's registered key: %v", err)
		}
		return request, body
	}
}

// AnswerInference answers a request as the leader's provider does: one
// encrypted content chunk, then the completion with its usage.
func (m *Member) AnswerInference(t testing.TB, ctx context.Context, request protocol.InferenceRequestMessage, content string, usage protocol.UsageInfo) {
	t.Helper()
	coordinator, err := e2e.ParsePublicKey(request.EncryptedBody.EphemeralPublicKey)
	if err != nil {
		t.Fatal(err)
	}
	delta, err := json.Marshal(map[string]any{"id": "chatcmpl-pair", "choices": []any{
		map[string]any{"delta": map[string]string{"content": content}}}})
	if err != nil {
		t.Fatal(err)
	}
	chunk, err := e2e.Encrypt([]byte("data: "+string(delta)+"\n\n"), coordinator, &m.process)
	if err != nil {
		t.Fatal(err)
	}
	m.write(t, ctx, protocol.InferenceResponseChunkMessage{Type: protocol.TypeInferenceResponseChunk,
		RequestID: request.RequestID, EncryptedData: &protocol.EncryptedPayload{
			EphemeralPublicKey: chunk.EphemeralPublicKey, Ciphertext: chunk.Ciphertext}})
	m.write(t, ctx, protocol.InferenceCompleteMessage{Type: protocol.TypeInferenceComplete,
		RequestID: request.RequestID, Usage: usage})
}

// EstablishPair plays both members through the control exchange the
// coordinator starts for them: preparation, owner start, the public key
// hellos and both key confirmations. members is in rank order. It returns
// each rank's prepare frame and canonical start.
func EstablishPair(t testing.TB, ctx context.Context, members [2]*Member) (prepares [2]protocol.NativePairMessage, starts [2][]byte) {
	t.Helper()
	for rank, m := range members {
		prepares[rank] = m.ReadNativePair(t, ctx, protocol.TypeNativePairPrepare)
		_, starts[rank] = PreparePayload(t, prepares[rank])
	}
	for rank, m := range members {
		m.SendNativePair(t, ctx, protocol.TypeNativePairPrepared, prepares[rank], starts[rank])
	}
	for _, m := range members {
		m.ReadNativePair(t, ctx, protocol.TypeNativePairOwnerStart)
	}
	for rank, m := range members {
		key := make([]byte, 32)
		key[0] = byte(rank + 1)
		m.SendNativePair(t, ctx, protocol.TypeNativePairHello, prepares[rank],
			append(append([]byte("DBNH\x01"), starts[rank]...), key...))
	}
	for _, m := range members {
		m.ReadNativePair(t, ctx, protocol.TypeNativePairBinding)
	}
	for rank, m := range members {
		confirmation := make([]byte, 32)
		confirmation[0] = byte(rank + 7)
		m.SendNativePair(t, ctx, protocol.TypeNativePairConfirmation, prepares[rank], confirmation)
	}
	for _, m := range members {
		m.ReadNativePair(t, ctx, protocol.TypeNativePairPeerConfirmation)
	}
	return prepares, starts
}

// SEPublicKey is the member's signing key as an attestation reports it.
func (m *Member) SEPublicKey() string {
	return base64.StdEncoding.EncodeToString(elliptic.Marshal(elliptic.P256(), m.se.X, m.se.Y))
}

// Frame is one coordinator frame with its type.
type Frame struct {
	Type string
	Data []byte
}

// Next reads one coordinator frame. ok is false when the socket ended or ctx
// expired.
func (m *Member) Next(ctx context.Context) (Frame, bool) {
	_, data, err := m.Conn.Read(ctx)
	if err != nil {
		return Frame{}, false
	}
	var envelope struct {
		Type string `json:"type"`
	}
	_ = json.Unmarshal(data, &envelope)
	return Frame{Type: envelope.Type, Data: data}, true
}

// ReadUntil returns every frame up to and including the first of the wanted
// type, failing the test if the socket ends first.
func (m *Member) ReadUntil(t testing.TB, ctx context.Context, wanted string) []Frame {
	t.Helper()
	var frames []Frame
	for {
		frame, ok := m.Next(ctx)
		if !ok {
			t.Fatalf("member socket ended before %s after %d frames", wanted, len(frames))
		}
		frames = append(frames, frame)
		if frame.Type == wanted {
			return frames
		}
	}
}

// ReadNativePair skips ordinary frames and decodes the next native-pair frame,
// which must be of the wanted kind.
func (m *Member) ReadNativePair(t testing.TB, ctx context.Context, wanted string) protocol.NativePairMessage {
	t.Helper()
	for {
		frame, ok := m.Next(ctx)
		if !ok {
			t.Fatalf("member socket ended before %s", wanted)
		}
		if !strings.HasPrefix(frame.Type, "native_pair_") {
			continue
		}
		decoded, err := protocol.DecodeNativePairMessage(frame.Data)
		if err != nil {
			t.Fatalf("coordinator sent a malformed %s: %v", frame.Type, err)
		}
		if decoded.Type != wanted {
			t.Fatalf("member received %s, want %s", decoded.Type, wanted)
		}
		return *decoded
	}
}

// SendNativePair signs and sends the next member control frame for the session
// the reference frame belongs to, with this connection's strict sequence.
func (m *Member) SendNativePair(t testing.TB, ctx context.Context, kind string, reference protocol.NativePairMessage, payload []byte) {
	t.Helper()
	m.sent++
	message := protocol.NativePairMessage{Type: kind, Version: 1, MemberNonce: m.Nonce,
		Epoch: reference.Epoch, Generation: reference.Generation, Sequence: m.sent,
		Payload: base64.StdEncoding.EncodeToString(payload)}
	signing, err := message.SigningBytes()
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(signing)
	signature, err := ecdsa.SignASN1(rand.Reader, m.se, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	message.Signature = base64.StdEncoding.EncodeToString(signature)
	m.write(t, ctx, message)
}

// PreparePayload splits a native_pair_prepare payload into the canonical
// coordinator policy and this rank's canonical authorization start.
func PreparePayload(t testing.TB, prepare protocol.NativePairMessage) (policy, start []byte) {
	t.Helper()
	payload, err := prepare.PayloadBytes()
	if err != nil {
		t.Fatal(err)
	}
	if len(payload) < 10 || string(payload[:6]) != "DBNPR\x01" {
		t.Fatal("prepare payload prefix violated")
	}
	policyLength := int(binary.BigEndian.Uint32(payload[6:10]))
	if len(payload) <= 10+policyLength {
		t.Fatal("prepare payload missing canonical start")
	}
	return payload[10 : 10+policyLength], payload[10+policyLength:]
}

// ReleaseReceipt is the member's complete owner-release receipt for a start:
// native cleanup, authenticated owner lease release and owner transport end.
func ReleaseReceipt(start []byte) []byte {
	digest := sha256.Sum256(start)
	return append([]byte("DBNR\x01"), append(digest[:], 1, 1, 1)...)
}

// GrantPairTrust FABRICATES the evidence a real member earns from Apple device
// attestation, APNs code identity and an approved release challenge, and binds
// this member's signing key and serial to the registered connection. The
// registry must use ReleasePolicyGeneration.
func GrantPairTrust(t testing.TB, p *registry.Provider, m *Member) {
	t.Helper()
	if !TryGrantPairTrust(p, m) {
		t.Fatal("fabricated release evidence refused")
	}
}

// TryGrantPairTrust is GrantPairTrust for a connection whose registration may
// still be in progress: it reports false while the registry refuses the
// fabricated release evidence, and may be called again.
func TryGrantPairTrust(p *registry.Provider, m *Member) bool {
	p.CompleteProviderStateRestore()
	p.Mu().Lock()
	p.Attested = true
	p.TrustLevel = registry.TrustHardware
	p.MDAVerified = true
	p.SEKeyBound = true
	p.CodeAttested = true
	p.FreshCodeAttested = true
	p.MetallibVerified = true
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.Mu().Unlock()
	se := m.SEPublicKey()
	p.SetAttestationResult(&attestation.VerificationResult{Valid: true, PublicKey: se,
		EncryptionPublicKey: m.ProcessKey, SerialNumber: m.Options.Serial, SecureEnclaveAvailable: true})
	return p.GrantApplicationEvidenceIfNotUntrusted(registry.ApplicationEvidence{SEPublicKey: se, Serial: m.Options.Serial,
		ProcessPublicKey: m.ProcessKey, BinaryHash: strings.Repeat("a", 64), MetallibHash: strings.Repeat("b", 64),
		Backend: registry.BackendMLXSwift, Version: "0.9.2", PolicyGeneration: ReleasePolicyGeneration, VerifiedAt: time.Now()})
}

// AwaitRegistration reads until the coordinator either acknowledges this
// member or ends the socket. It returns the acknowledged provider ID, or the
// close status that refused the registration.
func (m *Member) AwaitRegistration(ctx context.Context) (providerID string, refused websocket.StatusCode, accepted bool) {
	for {
		_, data, err := m.Conn.Read(ctx)
		if err != nil {
			return "", websocket.CloseStatus(err), false
		}
		var ack protocol.ClusterMemberAcceptedMessage
		if json.Unmarshal(data, &ack) == nil && ack.Type == protocol.TypeClusterMemberAccepted {
			return ack.ProviderID, 0, true
		}
	}
}
