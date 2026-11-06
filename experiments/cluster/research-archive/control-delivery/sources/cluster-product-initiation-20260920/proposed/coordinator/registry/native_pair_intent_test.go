package registry

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"math/big"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func configuredFixtureIntent(t *testing.T, f *nativePairFixture, rank int, change func(*protocol.NativePairIntent)) *protocol.NativePairIntentMessage {
	t.Helper()
	canonical, e := canonicalNativeRuntimeApproval(f.policy)
	if e != nil {
		t.Fatal(e)
	}
	value := protocol.NativePairIntent{ClusterID: "fixture-cluster", ApprovalID: f.policy.ID, PolicySHA256: sha256.Sum256(canonical), MemberIDs: [2]string{"member-0", "member-1"}, Rank: uint8(rank), LifetimeSeconds: 300}
	var serial string
	for i, p := range f.p {
		p.mu.Lock()
		key := p.AttestationResult.PublicKey
		if i == rank {
			serial = p.AttestationResult.SerialNumber
		}
		p.mu.Unlock()
		raw, e := base64.StdEncoding.DecodeString(key)
		if e != nil {
			t.Fatal(e)
		}
		value.SignerSHA256[i] = sha256.Sum256(raw)
	}
	if change != nil {
		change(&value)
	}
	raw, e := value.Canonical()
	if e != nil {
		t.Fatal(e)
	}
	f.c.mu.Lock()
	sequence := f.n[rank].inboundSequence + 1
	f.c.mu.Unlock()
	m := &protocol.NativePairIntentMessage{Type: protocol.TypeNativePairIntent, Version: 1, MemberNonce: f.n[rank].nonce, Sequence: sequence, Payload: base64.StdEncoding.EncodeToString(raw)}
	signed, e := m.SigningBytes()
	if e != nil {
		t.Fatal(e)
	}
	hash := sha256.Sum256(signed)
	d := new(big.Int).SetBytes([]byte(serial))
	x, y := elliptic.P256().ScalarBaseMult(d.Bytes())
	key := &ecdsa.PrivateKey{PublicKey: ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}, D: d}
	signature, e := ecdsa.SignASN1(rand.Reader, key, hash[:])
	if e != nil {
		t.Fatal(e)
	}
	m.Signature = base64.StdEncoding.EncodeToString(signature)
	return m
}
func requireNoConfiguredHold(t *testing.T, f *nativePairFixture) {
	t.Helper()
	f.c.mu.Lock()
	defer f.c.mu.Unlock()
	f.r.mu.RLock()
	defer f.r.mu.RUnlock()
	if len(f.c.sessions) != 0 || len(f.r.verifiedPairs.states) != 0 {
		t.Fatal("consent invented reservation/owner authority")
	}
}
func TestNativePairConfiguredStartRequiresMutualConsentThenOriginalCommit(t *testing.T) {
	f := newNativePairFixture(t)
	if e := f.c.Configure(f.n[1], configuredFixtureIntent(t, f, 1, nil)); e != nil {
		t.Fatal(e)
	}
	requireNoConfiguredHold(t, f)
	if e := f.c.Configure(f.n[0], configuredFixtureIntent(t, f, 0, nil)); e != nil {
		t.Fatal(e)
	}
	for rank := 0; rank < 2; rank++ {
		f.read(t, rank, protocol.TypeNativePairPrepare)
	}
	f.c.mu.Lock()
	s := f.n[0].session
	consumed := f.n[0].configuration.consumed && f.n[1].configuration.consumed
	f.c.mu.Unlock()
	if s == nil || !consumed || f.phase(s) != VerifiedPairPending {
		t.Fatal("fresh bilateral pending hold absent")
	}
	f.prepared(t, s, 0)
	if f.phase(s) != VerifiedPairPending {
		t.Fatal("single acknowledgment started owners")
	}
	f.prepared(t, s, 1)
	for rank := 0; rank < 2; rank++ {
		f.read(t, rank, protocol.TypeNativePairOwnerStart)
	}
	if f.phase(s) != VerifiedPairActive {
		t.Fatal("original registry did not commit")
	}
	f.c.Cancel(s)
	if f.phase(s) != VerifiedPairQuarantined {
		t.Fatal("active cancellation freed device")
	}
	if e := f.c.Configure(f.n[0], configuredFixtureIntent(t, f, 0, nil)); e == nil {
		t.Fatal("same connection configuration reused")
	}
}
func TestNativePairConfiguredSignerAndMembershipMismatchNeverReserve(t *testing.T) {
	for _, kind := range []string{"signature", "peer-key", "cluster", "rank"} {
		t.Run(kind, func(t *testing.T) {
			f := newNativePairFixture(t)
			follower := configuredFixtureIntent(t, f, 1, nil)
			leader := configuredFixtureIntent(t, f, 0, func(p *protocol.NativePairIntent) {
				if kind == "peer-key" {
					p.SignerSHA256[1][0] ^= 1
				}
				if kind == "cluster" {
					p.ClusterID = "foreign"
				}
				if kind == "rank" {
					p.Rank = 1
				}
			})
			if kind == "signature" {
				leader.Signature = base64.StdEncoding.EncodeToString(make([]byte, 8))
			}
			if e := f.c.Configure(f.n[1], follower); e != nil {
				t.Fatal(e)
			}
			if e := f.c.Configure(f.n[0], leader); e != nil {
				t.Fatal(e)
			}
			f.c.mu.Lock()
			record := f.n[0].configuration
			f.c.mu.Unlock()
			if _, _, ok := f.c.configuredSelection(f.n[0], record); ok {
				t.Fatal("mismatched intent selected")
			}
			requireNoConfiguredHold(t, f)
		})
	}
}
func TestNativePairConfiguredMissingRevokedAndChangedCatalogRefuse(t *testing.T) {
	for _, kind := range []string{"missing", "revoked", "changed"} {
		t.Run(kind, func(t *testing.T) {
			f := newNativePairFixture(t)
			message := configuredFixtureIntent(t, f, 0, func(p *protocol.NativePairIntent) {
				if kind == "missing" {
					p.ApprovalID = "absent"
				}
				if kind == "changed" {
					p.PolicySHA256[0] ^= 1
				}
			})
			if kind == "revoked" {
				f.c.RevokeApproval(f.policy.ID)
			}
			if e := f.c.Configure(f.n[0], message); e == nil {
				t.Fatal("unapproved catalog intent accepted")
			}
			requireNoConfiguredHold(t, f)
		})
	}
}
func TestNativePairConfiguredCurrentTrustMustBecomeReadyBeforeReserve(t *testing.T) {
	f := newNativePairFixture(t)
	f.p[0].mu.Lock()
	f.p[0].RuntimeVerified = false
	f.p[0].mu.Unlock()
	for rank := 1; rank >= 0; rank-- {
		if e := f.c.Configure(f.n[rank], configuredFixtureIntent(t, f, rank, nil)); e != nil {
			t.Fatal(e)
		}
	}
	f.c.mu.Lock()
	record := f.n[0].configuration
	f.c.mu.Unlock()
	if _, _, ok := f.c.configuredSelection(f.n[0], record); ok {
		t.Fatal("unverified member selected")
	}
	requireNoConfiguredHold(t, f)
	f.p[0].mu.Lock()
	f.p[0].RuntimeVerified = true
	f.p[0].mu.Unlock()
	for rank := 0; rank < 2; rank++ {
		f.read(t, rank, protocol.TypeNativePairPrepare)
	}
	f.c.mu.Lock()
	s := f.n[0].session
	f.c.mu.Unlock()
	if s == nil || f.phase(s) != VerifiedPairPending {
		t.Fatal("fresh trust did not enable genuine pending reservation")
	}
}
func TestNativePairConfiguredDisconnectAndExpiryCannotFollowReplacement(t *testing.T) {
	f := newNativePairFixture(t)
	if e := f.c.Configure(f.n[0], configuredFixtureIntent(t, f, 0, nil)); e != nil {
		t.Fatal(e)
	}
	f.c.mu.Lock()
	record := f.n[0].configuration
	stopConfiguredIntent(f.n[0])
	f.c.mu.Unlock()
	f.c.intentWorkers.Wait()
	f.c.mu.Lock()
	record.before = time.Now().Add(-time.Second)
	f.c.mu.Unlock()
	if _, _, ok := f.c.configuredSelection(f.n[0], record); ok {
		t.Fatal("expired leader intent selected")
	}
	f.c.Detach(f.n[0])
	if e := f.c.Configure(f.n[0], configuredFixtureIntent(t, f, 0, nil)); e == nil {
		t.Fatal("detached connection reused")
	}
	if e := f.c.Configure(f.n[1], configuredFixtureIntent(t, f, 1, nil)); e != nil {
		t.Fatal(e)
	}
	requireNoConfiguredHold(t, f)
	f.c.Close() // Must join the interrupted selector; not a native release receipt.
}
func TestNativePairConfiguredNonceSequenceAndDuplicatePublicationRefuse(t *testing.T) {
	for _, kind := range []string{"nonce", "sequence", "duplicate"} {
		t.Run(kind, func(t *testing.T) {
			f := newNativePairFixture(t)
			m := configuredFixtureIntent(t, f, 1, nil)
			if kind == "nonce" {
				m.MemberNonce = f.n[0].nonce
			}
			if kind == "sequence" {
				m.Sequence++
			}
			if kind == "duplicate" {
				if e := f.c.Configure(f.n[1], m); e != nil {
					t.Fatal(e)
				}
			}
			if e := f.c.Configure(f.n[1], m); e == nil {
				t.Fatal("invalid connection control accepted")
			}
			requireNoConfiguredHold(t, f)
		})
	}
}
