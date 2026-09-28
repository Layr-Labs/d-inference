package registry

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"nhooyr.io/websocket"
)

type nativePairFixture struct {
	r      *Registry
	c      *NativePairCoordinator
	p      [2]*Provider
	n      [2]*NativePairConnection
	frames [2]chan protocol.NativePairMessage
	policy NativeRuntimeApproval
}

func newNativePairFixture(t *testing.T) *nativePairFixture {
	t.Helper()
	r, p, request := pairTestRegistry(t)
	policy := NativeRuntimeApproval{ID: "fixture-explicit-native-policy", Model: request.Model, Generation: 11, PlanSHA256: request.PlanSHA256, Schedule: 2, MaximumPlaintext: 4096, MaximumTransportFrame: 4136, MaximumRecords: 64, MaximumCumulativePlaintext: 262144, AllowedChips: []string{"fixture-chip"}, NotAfter: time.Now().Add(time.Hour)}
	fields := []*[32]byte{&policy.ArtifactSHA256, &policy.NativeRuntimeSHA256, &policy.MetallibSHA256, &policy.ResourceLibrarySHA256, &policy.CapabilitySHA256, &policy.ResourcePolicySHA256, &policy.ProfileSHA256}
	for i, h := range fields {
		*h = sha256.Sum256([]byte(fmt.Sprint("approved-fixture-", i)))
	}
	catalog, e := NewNativeRuntimeCatalog([]NativeRuntimeApproval{policy})
	if e != nil {
		t.Fatal(e)
	}
	f := &nativePairFixture{r: r, p: p, c: NewNativePairCoordinator(r, catalog), policy: policy}
	t.Cleanup(f.c.Close)
	for rank, provider := range p {
		server, client := testWebSocketPair(t)
		provider.mu.Lock()
		provider.executionRole = protocol.ExecutionRoleClusterMember
		provider.memberNonce = strings.Repeat(fmt.Sprint(rank+1), 64)
		provider.Hardware.ChipName = "fixture-chip"
		provider.BackendCapacity.Slots = nil
		provider.CurrentModel = ""
		provider.WarmModels = nil
		provider.writer = newProviderWriter(server)
		provider.mu.Unlock()
		t.Cleanup(provider.closeWriterNow)
		// Registry fixture tests use actual WS writers plus explicit test TLS state;
		// this is not a claim that the helper's cleartext socket is a TLS deployment.
		f.n[rank], e = f.c.Attach(provider, provider.memberNonce, &tls.ConnectionState{HandshakeComplete: true})
		if e != nil {
			t.Fatal(e)
		}
		f.frames[rank] = make(chan protocol.NativePairMessage, 32)
		ctx, cancel := context.WithCancel(context.Background())
		t.Cleanup(cancel)
		go func(rank int, client *websocket.Conn) {
			for {
				_, b, e := client.Read(ctx)
				if e != nil {
					return
				}
				var m protocol.NativePairMessage
				if json.Unmarshal(b, &m) != nil {
					return
				}
				select {
				case f.frames[rank] <- m:
				case <-ctx.Done():
					return
				}
			}
		}(rank, client)
	}
	return f
}
func (f *nativePairFixture) reserve(t *testing.T) *NativePairSession {
	t.Helper()
	s, e := f.c.Reserve(f.n, f.policy.ID, time.Minute)
	if e != nil {
		t.Fatal(e)
	}
	for rank := range f.n {
		f.read(t, rank, protocol.TypeNativePairPrepare)
	}
	return s
}
func (f *nativePairFixture) read(t *testing.T, rank int, kind string) protocol.NativePairMessage {
	t.Helper()
	select {
	case m := <-f.frames[rank]:
		if m.Type != kind {
			t.Fatalf("rank%d got %s want %s", rank, m.Type, kind)
		}
		return m
	case <-time.After(2 * time.Second):
		t.Fatal("bounded public write absent")
	}
	return protocol.NativePairMessage{}
}
func (f *nativePairFixture) signed(t *testing.T, s *NativePairSession, rank int, kind string, payload []byte) *protocol.NativePairMessage {
	t.Helper()
	f.c.mu.Lock()
	seq := f.n[rank].inboundSequence + 1
	f.c.mu.Unlock()
	m := &protocol.NativePairMessage{Type: kind, Version: 1, MemberNonce: f.n[rank].nonce, Epoch: hex.EncodeToString(s.membership.Epoch[:]), Generation: s.membership.Generation, Sequence: seq, Payload: base64.StdEncoding.EncodeToString(payload)}
	b, e := m.SigningBytes()
	if e != nil {
		t.Fatal(e)
	}
	digest := sha256.Sum256(b)
	serial := s.membership.Members[rank].DeviceSerial
	d := new(big.Int).SetBytes([]byte(serial))
	x, y := elliptic.P256().ScalarBaseMult(d.Bytes())
	key := &ecdsa.PrivateKey{PublicKey: ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}, D: d}
	signature, e := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if e != nil {
		t.Fatal(e)
	}
	m.Signature = base64.StdEncoding.EncodeToString(signature)
	return m
}
func (f *nativePairFixture) prepared(t *testing.T, s *NativePairSession, rank int) {
	t.Helper()
	b, _ := s.starts[rank].Canonical()
	if e := f.c.Handle(f.n[rank], f.signed(t, s, rank, protocol.TypeNativePairPrepared, b)); e != nil {
		t.Fatal(e)
	}
}
func (f *nativePairFixture) active(t *testing.T) *NativePairSession {
	t.Helper()
	s := f.reserve(t)
	f.prepared(t, s, 0)
	f.prepared(t, s, 1)
	for rank := range f.n {
		f.read(t, rank, protocol.TypeNativePairOwnerStart)
	}
	return s
}
func (f *nativePairFixture) phase(s *NativePairSession) VerifiedPairPhase {
	f.r.mu.RLock()
	defer f.r.mu.RUnlock()
	return s.handle.state.phase
}
