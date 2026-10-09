package registry_test

// External behavior coverage of the staged verified-pair membership lifecycle
// and the native-pair public control relay. Everything here drives ONLY the
// production public API plus real local WebSocket wires — no registry or
// session internals. Wire-derived values (canonical starts, epoch, generation)
// are read from the actual outbound frames, never from session state.

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

const nativePairFixtureModel = "verified-pair-fixture-model"

// pairMember registers a fully trusted cluster member through the public
// Register path and the public trust/evidence setters — the same shape the
// real trust workflows produce, only faster. conn may be nil for suites that
// never relay.
func pairMember(t *testing.T, r *production.Registry, conn *websocket.Conn, id, serial, nonce string) *production.Provider {
	t.Helper()
	return pairMemberWith(t, r, conn, id, serial, nonce, nil)
}

// pairMemberWith is pairMember with the registration adjusted before it is
// sent, for members that also register a cluster membership.
func pairMemberWith(t *testing.T, r *production.Registry, conn *websocket.Conn, id, serial, nonce string, adjust func(*protocol.RegisterMessage)) *production.Provider {
	t.Helper()
	processKey := sha256.Sum256([]byte("fixture-process-" + id))
	se := pairDeviceSEKey(serial)
	msg := &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		ExecutionRole:           protocol.ExecutionRoleClusterMember,
		MemberRegistrationNonce: nonce,
		Models:                  []protocol.ModelInfo{},
		ClusterModels:           []protocol.ModelInfo{{ID: nativePairFixtureModel, SizeBytes: 5_000_000_000}},
		Hardware:                protocol.Hardware{ChipName: "fixture-chip", MemoryGB: 64},
		Backend:                 "mlx-swift",
		Version:                 "0.9.2",
		PublicKey:               base64.StdEncoding.EncodeToString(processKey[:]),
		EncryptedResponseChunks: true,
		PrivacyCapabilities: &protocol.PrivacyCapabilities{
			TextBackendInprocess: true, TextProxyDisabled: true, SIPEnabled: true,
			AntiDebugEnabled: true, CoreDumpsDisabled: true, EnvScrubbed: true,
		},
	}
	if adjust != nil {
		adjust(msg)
	}
	p := r.Register(id, conn, msg)
	if p == nil {
		t.Fatal("member registration refused")
	}
	trustPairDevice(t, p, serial, se, &protocol.BackendCapacity{TotalMemoryGB: 64})
	return p
}

// trustPairDevice gives a registered fixture connection the hardware, code and
// release evidence of the device identified by serial and its SE key.
func trustPairDevice(t *testing.T, p *production.Provider, serial, se string, capacity *protocol.BackendCapacity) {
	t.Helper()
	p.Mu().Lock()
	p.Attested = true
	p.TrustLevel = production.TrustHardware
	p.MDAVerified = true
	p.SEKeyBound = true
	p.CodeAttested = true
	p.FreshCodeAttested = true
	p.MetallibVerified = true
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.BackendCapacity = capacity
	p.Mu().Unlock()
	p.SetAttestationResult(&attestation.VerificationResult{Valid: true, PublicKey: se,
		EncryptionPublicKey: p.PublicKey, SerialNumber: serial, SecureEnclaveAvailable: true})
	if !p.GrantApplicationEvidenceIfNotUntrusted(production.ApplicationEvidence{SEPublicKey: se, Serial: serial,
		ProcessPublicKey: p.PublicKey, BinaryHash: strings.Repeat("a", 64), MetallibHash: strings.Repeat("b", 64),
		Backend: p.Backend, Version: p.Version, PolicyGeneration: 7, VerifiedAt: time.Now()}) {
		t.Fatal("fixture current release evidence refused")
	}
}

// pairDeviceSEKey is the fixture Secure Enclave public key of a device serial.
func pairDeviceSEKey(serial string) string {
	x, y := elliptic.P256().ScalarBaseMult([]byte(serial))
	return base64.StdEncoding.EncodeToString(elliptic.Marshal(elliptic.P256(), x, y))
}

func pairEnvironment(t *testing.T) *production.Registry {
	t.Helper()
	return pairEnvironmentWith(t, production.Dependencies{})
}

func pairEnvironmentWith(t *testing.T, dependencies production.Dependencies) *production.Registry {
	t.Helper()
	r := production.NewWithDependencies(testLogger(), dependencies)
	r.SetModelCatalog([]production.CatalogEntry{{ID: nativePairFixtureModel}})
	r.SetReleasePolicyGeneration(7, true, nil)
	return r
}

func pairRequest() production.VerifiedPairRequest {
	return production.VerifiedPairRequest{Model: nativePairFixtureModel,
		PlanSHA256:                   sha256.Sum256([]byte("fixture-plan")),
		ProposedRuntimeBindingSHA256: sha256.Sum256([]byte("UNAPPROVED-native-binding")),
		Lifetime:                     time.Minute}
}

// --- Registry lifecycle (no relay): fencing, phases, expiry, disconnect. ---

func TestVerifiedPairLifecycleThroughPublicAPI(t *testing.T) {
	r := pairEnvironment(t)
	members := [2]*production.Provider{
		pairMember(t, r, nil, "pair-a", "serial-a", strings.Repeat("1", 64)),
		pairMember(t, r, nil, "pair-b", "serial-b", strings.Repeat("2", 64)),
	}
	h, m, err := r.ReserveVerifiedPair(members, pairRequest())
	if err != nil {
		t.Fatalf("reserve: %v", err)
	}
	if m.Members[0].DeviceSerial != "serial-a" || m.Members[1].DeviceSerial != "serial-b" ||
		m.Generation == 0 || m.Suite != production.VerifiedPairSuite {
		t.Fatal("membership lost live identity binding")
	}
	// Fencing: the same physical device cannot be doubly held.
	if _, _, err = r.ReserveVerifiedPair(members, pairRequest()); err == nil {
		t.Fatal("held device admitted to a second pair")
	}
	// Wrong transcript and duplicate preparation are stale.
	if err = r.AcknowledgeVerifiedPairPrepared(h, members[0], sha256.Sum256([]byte("wrong"))); err == nil {
		t.Fatal("wrong transcript admitted")
	}
	if err = r.AcknowledgeVerifiedPairPrepared(h, members[0], m.TranscriptSHA256); err != nil {
		t.Fatalf("prepare rank0: %v", err)
	}
	if err = r.AcknowledgeVerifiedPairPrepared(h, members[0], m.TranscriptSHA256); err == nil {
		t.Fatal("duplicate preparation admitted")
	}
	// Commit before both preparations is an invalid transition.
	if _, err = r.CommitVerifiedPairOwners(h); err == nil {
		t.Fatal("commit admitted before bilateral preparation")
	}
	if err = r.AcknowledgeVerifiedPairPrepared(h, members[1], m.TranscriptSHA256); err != nil {
		t.Fatalf("prepare rank1: %v", err)
	}
	committed, err := r.CommitVerifiedPairOwners(h)
	if err != nil {
		t.Fatalf("commit: %v", err)
	}
	if committed.TranscriptSHA256 != m.TranscriptSHA256 {
		t.Fatal("commit substituted membership")
	}
	if _, err = r.ValidateVerifiedPair(h); err != nil {
		t.Fatalf("active pair failed validation: %v", err)
	}
	// Cancellation publishes invalidation; bilateral release observations then
	// complete the lifecycle; a third observation is stale.
	if err = r.CancelVerifiedPair(h); err != nil {
		t.Fatalf("cancel: %v", err)
	}
	select {
	case <-h.Done():
	case <-time.After(time.Second):
		t.Fatal("cancel was not published")
	}
	if err = r.ObserveVerifiedPairOwnerReleased(h, members[0], m.TranscriptSHA256); err != nil {
		t.Fatalf("release rank0: %v", err)
	}
	if err = r.ObserveVerifiedPairOwnerReleased(h, members[0], m.TranscriptSHA256); err == nil {
		t.Fatal("duplicate release observation admitted")
	}
	if err = r.ObserveVerifiedPairOwnerReleased(h, members[1], m.TranscriptSHA256); err != nil {
		t.Fatalf("release rank1: %v", err)
	}
	// After a complete release the device is selectable again.
	if _, _, err = r.ReserveVerifiedPair(members, pairRequest()); err != nil {
		t.Fatalf("released device refused re-selection: %v", err)
	}
}

func TestVerifiedPairDisconnectFencesReplacement(t *testing.T) {
	r := pairEnvironment(t)
	old := pairMember(t, r, nil, "pair-a", "serial-a", strings.Repeat("1", 64))
	peer := pairMember(t, r, nil, "pair-b", "serial-b", strings.Repeat("2", 64))
	members := [2]*production.Provider{old, peer}
	h, m, err := r.ReserveVerifiedPair(members, pairRequest())
	if err != nil {
		t.Fatalf("reserve: %v", err)
	}
	for _, p := range members {
		if err = r.AcknowledgeVerifiedPairPrepared(h, p, m.TranscriptSHA256); err != nil {
			t.Fatalf("prepare: %v", err)
		}
	}
	if _, err = r.CommitVerifiedPairOwners(h); err != nil {
		t.Fatalf("commit: %v", err)
	}
	// Losing the connection quarantines; it never frees an active owner.
	r.Disconnect(old.ID)
	select {
	case <-h.Done():
	case <-time.After(time.Second):
		t.Fatal("disconnect did not publish invalidation")
	}
	replacement := pairMember(t, r, nil, "replacement-a", "serial-a", strings.Repeat("3", 64))
	if err = r.ObserveVerifiedPairOwnerReleased(h, replacement, m.TranscriptSHA256); err == nil {
		t.Fatal("replacement released the old owner")
	}
	// The peer's ordinary rejoin path is fenced too: the old session's state
	// cannot be released by an unrecognized connection.
	if err = r.ObserveVerifiedPairOwnerReleased(h, peer, m.TranscriptSHA256); err != nil {
		t.Fatal("original peer could not complete its own release observation")
	}
}

func TestVerifiedPairExpiryAndInputValidation(t *testing.T) {
	r := pairEnvironment(t)
	members := [2]*production.Provider{
		pairMember(t, r, nil, "pair-a", "serial-a", strings.Repeat("1", 64)),
		pairMember(t, r, nil, "pair-b", "serial-b", strings.Repeat("2", 64)),
	}
	// Closed input validation.
	bad := pairRequest()
	bad.Lifetime = 0
	if _, _, err := r.ReserveVerifiedPair(members, bad); err == nil {
		t.Fatal("zero lifetime admitted")
	}
	one := [2]*production.Provider{members[0], members[0]}
	if _, _, err := r.ReserveVerifiedPair(one, pairRequest()); err == nil {
		t.Fatal("same device twice admitted")
	}
	// A fixed original lifetime expires without any owner-release claim.
	req := pairRequest()
	req.Lifetime = 400 * time.Millisecond
	h, _, err := r.ReserveVerifiedPair(members, req)
	if err != nil {
		t.Fatalf("reserve: %v", err)
	}
	select {
	case <-h.Done():
	case <-time.After(2 * time.Second):
		t.Fatal("original fixed lifetime did not expire")
	}
}

// --- Native-pair public control relay over real local wires. ---

type nativePairWireFixture struct {
	r       *production.Registry
	c       *production.NativePairCoordinator
	p       [2]*production.Provider
	n       [2]*production.NativePairConnection
	frames  [2]chan protocol.NativePairMessage
	policy  production.NativeRuntimeApproval
	nonces  [2]string
	sent    [2]uint64
	starts  [2][]byte
	epoch   string
	gen     uint64
	serials [2]string
}

// newNativePairFixture builds the approved-policy coordinator over r with no
// member attached yet.
func newNativePairFixture(t *testing.T, r *production.Registry) *nativePairWireFixture {
	t.Helper()
	policy := production.NativeRuntimeApproval{ID: "fixture-explicit-native-policy", Model: nativePairFixtureModel,
		Generation: 11, PlanSHA256: sha256.Sum256([]byte("fixture-plan")), Schedule: 2,
		MaximumPlaintext: 4096, MaximumTransportFrame: 4136, MaximumRecords: 64, MaximumCumulativePlaintext: 262144,
		AllowedChips: []string{"fixture-chip"}, NotAfter: time.Now().Add(time.Hour)}
	fields := []*[32]byte{&policy.ArtifactSHA256, &policy.NativeRuntimeSHA256, &policy.MetallibSHA256,
		&policy.ResourceLibrarySHA256, &policy.CapabilitySHA256, &policy.ResourcePolicySHA256, &policy.ProfileSHA256}
	for i, h := range fields {
		*h = sha256.Sum256([]byte(fmt.Sprint("approved-fixture-", i)))
	}
	catalog, err := production.NewNativeRuntimeCatalog([]production.NativeRuntimeApproval{policy})
	if err != nil {
		t.Fatal(err)
	}
	f := &nativePairWireFixture{r: r, policy: policy, serials: [2]string{"serial-a", "serial-b"},
		nonces: [2]string{strings.Repeat("1", 64), strings.Repeat("2", 64)}}
	f.c = production.NewNativePairCoordinator(r, catalog)
	if f.c == nil {
		t.Fatal("approved catalog did not construct the coordinator")
	}
	return f
}

func newNativePairWireFixture(t *testing.T) *nativePairWireFixture {
	t.Helper()
	r := pairEnvironment(t)
	f := newNativePairFixture(t, r)
	t.Cleanup(f.c.Close)
	for rank := range f.p {
		server, client := testWebSocketPair(t)
		ids := [2]string{"pair-a", "pair-b"}
		f.p[rank] = pairMember(t, r, server, ids[rank], f.serials[rank], f.nonces[rank])
		// Explicit test TLS state; this is not a claim that the helper's
		// cleartext socket is a TLS deployment.
		n, err := f.c.Attach(f.p[rank], f.nonces[rank], production.NativePairDirectTLS(&tls.ConnectionState{HandshakeComplete: true}))
		if err != nil {
			t.Fatalf("attach rank%d: %v", rank, err)
		}
		f.n[rank] = n
		f.frames[rank] = make(chan protocol.NativePairMessage, 32)
		ctx, cancel := context.WithCancel(context.Background())
		t.Cleanup(cancel)
		go func(rank int, client *websocket.Conn) {
			for {
				_, b, err := client.Read(ctx)
				if err != nil {
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

func (f *nativePairWireFixture) read(t *testing.T, rank int, kind string) protocol.NativePairMessage {
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

// sign builds a syntactically valid, correctly sequenced, SE-signed inbound
// frame exactly as the member's Secure Enclave path would, with the fixture's
// serial-derived key.
func (f *nativePairWireFixture) sign(t *testing.T, rank int, kind string, payload []byte) *protocol.NativePairMessage {
	t.Helper()
	f.sent[rank]++
	m := &protocol.NativePairMessage{Type: kind, Version: 1, MemberNonce: f.nonces[rank],
		Epoch: f.epoch, Generation: f.gen, Sequence: f.sent[rank],
		Payload: base64.StdEncoding.EncodeToString(payload)}
	b, err := m.SigningBytes()
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(b)
	d := new(big.Int).SetBytes([]byte(f.serials[rank]))
	x, y := elliptic.P256().ScalarBaseMult(d.Bytes())
	key := &ecdsa.PrivateKey{PublicKey: ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}, D: d}
	signature, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	m.Signature = base64.StdEncoding.EncodeToString(signature)
	return m
}

func parsePrepareStart(t *testing.T, m protocol.NativePairMessage) []byte {
	t.Helper()
	payload, err := m.PayloadBytes()
	if err != nil {
		t.Fatal(err)
	}
	if len(payload) < 10 || string(payload[:6]) != "DBNPR\x01" {
		t.Fatal("prepare payload prefix violated")
	}
	policyLen := int(binary.BigEndian.Uint32(payload[6:10]))
	if len(payload) <= 10+policyLen {
		t.Fatal("prepare payload missing canonical start")
	}
	return payload[10+policyLen:]
}

func (f *nativePairWireFixture) reserve(t *testing.T) *production.NativePairSession {
	t.Helper()
	s, err := f.c.Reserve(f.n, f.policy.ID, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	f.readPrepares(t)
	return s
}

// readPrepares reads both ranks' prepare frames and adopts that session's
// epoch, generation and starts for the frames the fixture signs next. It
// returns the rank-0 frame.
func (f *nativePairWireFixture) readPrepares(t *testing.T) protocol.NativePairMessage {
	t.Helper()
	var first protocol.NativePairMessage
	for rank := range f.n {
		m := f.read(t, rank, protocol.TypeNativePairPrepare)
		f.starts[rank] = parsePrepareStart(t, m)
		if rank == 0 {
			first, f.epoch, f.gen = m, m.Epoch, m.Generation
		} else if m.Epoch != f.epoch || m.Generation != f.gen {
			t.Fatal("ranks disagree on membership")
		}
	}
	return first
}

func (f *nativePairWireFixture) prepared(t *testing.T, rank int) {
	t.Helper()
	if err := f.c.Handle(f.n[rank], f.sign(t, rank, protocol.TypeNativePairPrepared, f.starts[rank])); err != nil {
		t.Fatalf("prepared rank%d: %v", rank, err)
	}
}

func releaseReceipt(start []byte) []byte {
	digest := sha256.Sum256(start)
	// Native cleanup, authenticated owner lease-release ACK, actual owner
	// transport termination. A future member may emit this only after all 3.
	return append([]byte("DBNR\x01"), append(digest[:], 1, 1, 1)...)
}

func TestNativePairRelayFullLifecycleOverWire(t *testing.T) {
	f := newNativePairWireFixture(t)
	s := f.reserve(t)
	// No owner start may be published before bilateral preparation.
	f.prepared(t, 0)
	for _, ch := range f.frames {
		select {
		case m := <-ch:
			t.Fatalf("start before both prepared: %s", m.Type)
		default:
		}
	}
	f.prepared(t, 1)
	var starts [2][]byte
	for rank := range f.n {
		m := f.read(t, rank, protocol.TypeNativePairOwnerStart)
		payload, err := m.PayloadBytes()
		if err != nil {
			t.Fatal(err)
		}
		starts[rank] = payload
	}
	if string(starts[0]) == string(starts[1]) {
		t.Fatal("ranks received identical starts")
	}
	// Key hellos bind the exact committed starts; the coordinator returns the
	// ordered pair of validated hellos to both ranks.
	hellos := [2][]byte{}
	for rank := range f.n {
		key := make([]byte, 32)
		key[0] = byte(9 + rank)
		hellos[rank] = append(append([]byte("DBNH\x01"), starts[rank]...), key...)
		if err := f.c.Handle(f.n[rank], f.sign(t, rank, protocol.TypeNativePairHello, hellos[rank])); err != nil {
			t.Fatalf("hello rank%d: %v", rank, err)
		}
	}
	expected := append(append([]byte("DBNB\x01"), hellos[0]...), hellos[1]...)
	for rank := range f.n {
		m := f.read(t, rank, protocol.TypeNativePairBinding)
		payload, err := m.PayloadBytes()
		if err != nil {
			t.Fatal(err)
		}
		if string(payload) != string(expected) {
			t.Fatalf("rank%d binding not the exact ordered hellos", rank)
		}
	}
	// Cancellation publishes invalidation without fabricating release.
	if err := f.c.Handle(f.n[0], f.sign(t, 0, protocol.TypeNativePairCancel, []byte("DBNC\x01"))); err != nil {
		t.Fatal(err)
	}
	select {
	case <-s.Done():
	case <-time.After(time.Second):
		t.Fatal("cancel was not published")
	}
	// Only complete bilateral cleanup observations retire the session.
	if err := f.c.Handle(f.n[0], f.sign(t, 0, protocol.TypeNativePairOwnerReleased, releaseReceipt(starts[0]))); err != nil {
		t.Fatalf("release rank0: %v", err)
	}
	if err := f.c.Handle(f.n[1], f.sign(t, 1, protocol.TypeNativePairOwnerReleased, releaseReceipt(starts[1]))); err != nil {
		t.Fatalf("release rank1: %v", err)
	}
	ctx, stop := context.WithTimeout(context.Background(), time.Second)
	defer stop()
	if err := s.WaitControlStopped(ctx); err != nil {
		t.Fatal("public relay writers did not join", err)
	}
}

func TestNativePairNegativeSecurityCases(t *testing.T) {
	t.Run("solo attachment refused", func(t *testing.T) {
		r := pairEnvironment(t)
		msg := &protocol.RegisterMessage{Type: protocol.TypeRegister, Models: []protocol.ModelInfo{{ID: nativePairFixtureModel}}}
		p := r.Register("solo", nil, msg)
		t.Cleanup(func() { r.Disconnect(p.ID) })
		catalog, err := production.NewNativeRuntimeCatalog([]production.NativeRuntimeApproval{{
			ID: "fixture", Model: nativePairFixtureModel, Generation: 1,
			PlanSHA256: sha256.Sum256([]byte("p")), ArtifactSHA256: sha256.Sum256([]byte("a")),
			NativeRuntimeSHA256: sha256.Sum256([]byte("n")), MetallibSHA256: sha256.Sum256([]byte("m")),
			ResourceLibrarySHA256: sha256.Sum256([]byte("r")), CapabilitySHA256: sha256.Sum256([]byte("c")),
			ResourcePolicySHA256: sha256.Sum256([]byte("rp")), ProfileSHA256: sha256.Sum256([]byte("pr")),
			Schedule: 1, MaximumTransportFrame: 4136, MaximumPlaintext: 4096, MaximumRecords: 64,
			MaximumCumulativePlaintext: 262144, AllowedChips: []string{"fixture-chip"}, NotAfter: time.Now().Add(time.Hour)}})
		if err != nil {
			t.Fatal(err)
		}
		c := production.NewNativePairCoordinator(r, catalog)
		defer c.Close()
		if _, err = c.Attach(p, strings.Repeat("3", 64), production.NativePairDirectTLS(&tls.ConnectionState{HandshakeComplete: true})); err == nil {
			t.Fatal("solo provider attached as member")
		}
	})
	t.Run("nil and malformed catalogs fail closed", func(t *testing.T) {
		r := pairEnvironment(t)
		if production.NewNativePairCoordinator(r, nil) != nil {
			t.Fatal("nil catalog enabled the coordinator")
		}
		bad := production.NativeRuntimeApproval{ID: "bad", Model: "m", Generation: 1,
			Schedule: 1, MaximumTransportFrame: 4096, MaximumPlaintext: 4096,
			NotAfter: time.Now().Add(time.Hour)}
		if _, err := production.NewNativeRuntimeCatalog([]production.NativeRuntimeApproval{bad}); err == nil {
			t.Fatal("omitted AEAD overhead admitted")
		}
	})
	t.Run("false cleanup and replay never release", func(t *testing.T) {
		f := newNativePairWireFixture(t)
		f.reserve(t)
		f.prepared(t, 0)
		f.prepared(t, 1)
		for rank := range f.n {
			f.read(t, rank, protocol.TypeNativePairOwnerStart)
		}
		receipt := releaseReceipt(f.starts[0])
		receipt[len(receipt)-1] = 0 // fabricated: transport termination flag cleared
		m := f.sign(t, 0, protocol.TypeNativePairOwnerReleased, receipt)
		if err := f.c.Handle(f.n[0], m); err == nil {
			t.Fatal("incomplete cleanup admitted")
		}
		if err := f.c.Handle(f.n[0], m); err == nil {
			t.Fatal("replayed frame admitted")
		}
	})
	t.Run("substituted member identity refused", func(t *testing.T) {
		for _, mutation := range []string{"nonce", "peer", "signature"} {
			t.Run(mutation, func(t *testing.T) {
				f := newNativePairWireFixture(t)
				f.reserve(t)
				f.prepared(t, 0)
				f.prepared(t, 1)
				for rank := range f.n {
					f.read(t, rank, protocol.TypeNativePairOwnerStart)
				}
				m := f.sign(t, 0, protocol.TypeNativePairCancel, []byte("DBNC\x01"))
				connection := f.n[0]
				switch mutation {
				case "nonce":
					m.MemberNonce = f.nonces[1]
				case "peer":
					connection = f.n[1]
				case "signature":
					m.Signature = "MAYCAQECAQE="
				}
				if err := f.c.Handle(connection, m); err == nil {
					t.Fatal("substituted bound member message admitted")
				}
			})
		}
	})
	t.Run("fixed lifetime expires without owner release", func(t *testing.T) {
		f := newNativePairWireFixture(t)
		s, err := f.c.Reserve(f.n, f.policy.ID, 400*time.Millisecond)
		if err != nil {
			t.Fatal(err)
		}
		m := f.read(t, 0, protocol.TypeNativePairPrepare)
		f.epoch, f.gen = m.Epoch, m.Generation
		f.starts[0] = parsePrepareStart(t, m)
		m1 := f.read(t, 1, protocol.TypeNativePairPrepare)
		f.starts[1] = parsePrepareStart(t, m1)
		original := m.ExpiresAtUnixNano
		for rank := range f.n {
			f.prepared(t, rank)
		}
		for rank := range f.n {
			start := f.read(t, rank, protocol.TypeNativePairOwnerStart)
			if start.ExpiresAtUnixNano != original {
				t.Fatal("start refreshed the original lifetime")
			}
		}
		select {
		case <-s.Done():
		case <-time.After(2 * time.Second):
			t.Fatal("original fixed lifetime did not expire")
		}
	})
}

func TestNativePairApprovalRevocationFencesGrant(t *testing.T) {
	f := newNativePairWireFixture(t)
	s := f.reserve(t)
	f.prepared(t, 0)
	f.c.RevokeApproval(f.policy.ID)
	select {
	case <-s.Done():
	case <-time.After(time.Second):
		t.Fatal("revocation was not published")
	}
	if err := f.c.Handle(f.n[1], f.sign(t, 1, protocol.TypeNativePairPrepared, f.starts[1])); err == nil {
		t.Fatal("revoked grant committed")
	}
	// A supplied runtime hash is not an approval ID.
	if _, err := f.c.Reserve(f.n, hex.EncodeToString(f.policy.NativeRuntimeSHA256[:]), time.Minute); err == nil {
		t.Fatal("supplied runtime hash became approval")
	}
}

// The API passes the accepted request's actual TLS state, never a forwarded
// header or a provider claim. Plain HTTP with a spoofed forwarding header must
// not attach; only a real completed handshake may.
func TestNativePairAttachRequiresActualTLSState(t *testing.T) {
	r := pairEnvironment(t)
	nonce := strings.Repeat("3", 64)
	p := pairMember(t, r, nil, "tls-fixture", "serial-tls", nonce)
	t.Cleanup(func() { r.Disconnect(p.ID) })
	hash := sha256.Sum256([]byte("fixture"))
	catalog, err := production.NewNativeRuntimeCatalog([]production.NativeRuntimeApproval{{
		ID: "fixture", Model: nativePairFixtureModel, Generation: 1, PlanSHA256: hash,
		ArtifactSHA256: hash, NativeRuntimeSHA256: hash, MetallibSHA256: hash,
		ResourceLibrarySHA256: hash, CapabilitySHA256: hash, ResourcePolicySHA256: hash,
		ProfileSHA256: hash, Schedule: 1, MaximumTransportFrame: 4136, MaximumPlaintext: 4096,
		MaximumRecords: 64, MaximumCumulativePlaintext: 262144,
		AllowedChips: []string{"fixture-chip"}, NotAfter: time.Now().Add(time.Hour)}})
	if err != nil {
		t.Fatal(err)
	}
	c := production.NewNativePairCoordinator(r, catalog)
	defer c.Close()
	handler := http.HandlerFunc(func(w http.ResponseWriter, q *http.Request) {
		n, err := c.Attach(p, nonce, production.NativePairDirectTLS(q.TLS))
		if err != nil {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		c.Detach(n)
		w.WriteHeader(http.StatusNoContent)
	})
	plain := httptest.NewServer(handler)
	defer plain.Close()
	request, _ := http.NewRequest(http.MethodGet, plain.URL, nil)
	request.Header.Set("X-Forwarded-Proto", "https")
	response, err := plain.Client().Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusForbidden {
		t.Fatal("forwarded header substituted for actual TLS state")
	}
	secured := httptest.NewTLSServer(handler)
	defer secured.Close()
	securedRequest, _ := http.NewRequest(http.MethodGet, secured.URL, nil)
	securedResponse, err := secured.Client().Do(securedRequest)
	if err != nil {
		t.Fatal(err)
	}
	securedResponse.Body.Close()
	if securedResponse.StatusCode != http.StatusNoContent {
		t.Fatal("actual TLS state refused")
	}
}
