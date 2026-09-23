package appattest

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/binary"
	"math/big"
	"testing"
	"time"

	"github.com/fxamacker/cbor/v2"
)

type fixture struct {
	verifier      *Verifier
	private       *ecdsa.PrivateKey
	proof, public []byte
	keyID         string
	hash          [32]byte
}

func makeFixture(t *testing.T, acl bool) fixture {
	t.Helper()
	return makeFixtureWithAuth(t, acl, nil)
}

func makeFixtureWithAuth(t *testing.T, acl bool, transform func([]byte) []byte) fixture {
	t.Helper()
	now := time.Now()
	rootKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	root := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "TEST ONLY"}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	rootDER, err := x509.CreateCertificate(rand.Reader, root, root, &rootKey.PublicKey, rootKey)
	if err != nil {
		t.Fatal(err)
	}
	root, _ = x509.ParseCertificate(rootDER)
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	public := elliptic.Marshal(key.Curve, key.X, key.Y)
	id := sha256.Sum256(public)
	keyID := base64.StdEncoding.EncodeToString(id[:])
	hash := sha256.Sum256([]byte("fresh server transcript"))
	auth := testAuth(t, key, 0, true, "production")
	if transform != nil {
		auth = transform(auth)
	}
	nonce := digest(auth, hash)
	wrap := func(b []byte) []byte {
		data, _ := asn1.Marshal(struct {
			Value []byte `asn1:"explicit,tag:1"`
		}{b})
		return data
	}
	leaf := &x509.Certificate{SerialNumber: big.NewInt(2), NotBefore: now.Add(-time.Minute), NotAfter: now.Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature,
		ExtraExtensions: []pkix.Extension{{Id: asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 2}, Value: wrap(nonce[:])}}}
	if acl {
		value, _ := base64.StdEncoding.DecodeString("MEAMAjExMDowCQwCb2uhAwEB/zAJDAJvYaEDAQH/MAsMBG9kZWyhAwEB/zAVDARvc2duoAYMBHJzZWMwBaYDAgEB")
		leaf.ExtraExtensions = append(leaf.ExtraExtensions, pkix.Extension{Id: asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 6}, Value: wrap(value)})
	}
	der, err := x509.CreateCertificate(rand.Reader, leaf, root, &key.PublicKey, rootKey)
	if err != nil {
		t.Fatal(err)
	}
	proof, _ := cbor.Marshal(map[string]any{"fmt": "apple-appattest", "authData": auth, "attStmt": map[string]any{"x5c": [][]byte{der, rootDER}, "receipt": []byte("unused shadow receipt")}})
	roots := x509.NewCertPool()
	roots.AddCert(root)
	return fixture{&Verifier{Policy{"TEST.app", "production"}, roots, time.Now}, key, proof, public, keyID, hash}
}

func testAuth(t *testing.T, key *ecdsa.PrivateKey, counter uint32, attestation bool, environment string) []byte {
	t.Helper()
	rp := sha256.Sum256([]byte("TEST.app"))
	b := append([]byte{}, rp[:]...)
	flags := byte(0x80)
	if attestation {
		flags |= 0x40
	}
	b = append(b, flags)
	var count [4]byte
	binary.BigEndian.PutUint32(count[:], counter)
	b = append(b, count[:]...)
	if attestation {
		aaguid := append([]byte("appattest"), make([]byte, 7)...)
		if environment == "development" {
			aaguid = []byte("appattestdevelop")
		}
		b = append(b, aaguid...)
		b = append(b, 0, 32)
		public := elliptic.Marshal(key.Curve, key.X, key.Y)
		id := sha256.Sum256(public)
		b = append(b, id[:]...)
		cose, _ := cbor.Marshal(map[int]any{1: 2, 3: -7, -1: 1, -2: public[1:33], -3: public[33:]})
		b = append(b, cose...)
	}
	ext, _ := cbor.Marshal(map[string]any{"apple_bundle_version_01": "0.9.2", "apple_validation_category_01": []byte{6, 0, 0, 0}})
	return append(b, ext...)
}

func assertion(t *testing.T, f fixture, counter uint32, hash [32]byte) []byte {
	t.Helper()
	auth := testAuth(t, f.private, counter, false, "production")
	nonce := digest(auth, hash)
	nonce = sha256.Sum256(nonce[:])
	sig, _ := ecdsa.SignASN1(rand.Reader, f.private, nonce[:])
	proof, _ := cbor.Marshal(map[string]any{"signature": sig, "authenticatorData": auth})
	return proof
}

func TestAppAttestRoundTripAndFailures(t *testing.T) {
	f := makeFixture(t, true)
	key, err := f.verifier.Attestation(f.proof, f.keyID, f.hash)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(key.PublicKey, f.public) || key.BundleVersion != "0.9.2" || key.ValidationCategory == nil || *key.ValidationCategory != 6 {
		t.Fatalf("wrong metadata: %+v", key)
	}
	proof := assertion(t, f, 1, f.hash)
	count, _, err := f.verifier.Assertion(proof, key.PublicKey, f.hash, 0)
	if err != nil || count != 1 {
		t.Fatalf("assertion: %d %v", count, err)
	}
	if _, _, err := f.verifier.Assertion(proof, key.PublicKey, f.hash, 1); err == nil {
		t.Fatal("replayed counter accepted")
	}
	wrong := sha256.Sum256([]byte("different session or key"))
	if _, _, err := f.verifier.Assertion(proof, key.PublicKey, wrong, 0); err == nil {
		t.Fatal("wrong transcript accepted")
	}
	if _, err := f.verifier.Attestation(f.proof, f.keyID, wrong); err == nil {
		t.Fatal("wrong nonce accepted")
	}
	if _, err := f.verifier.Attestation(f.proof, base64.StdEncoding.EncodeToString(make([]byte, 32)), f.hash); err == nil {
		t.Fatal("wrong key accepted")
	}
	if _, err := New(Policy{"TEST.app", "production"}).Attestation(f.proof, f.keyID, f.hash); err == nil {
		t.Fatal("production accepted test root")
	}
	f.verifier.policy.Environment = "development"
	if _, err := f.verifier.Attestation(f.proof, f.keyID, f.hash); err == nil {
		t.Fatal("production proof accepted as development")
	}
}

func TestAppAttestMacACLIsRequired(t *testing.T) {
	f := makeFixture(t, false)
	if _, err := f.verifier.Attestation(f.proof, f.keyID, f.hash); err == nil || err.Error() != "mac_acl" {
		t.Fatalf("missing Mac ACL: %v", err)
	}
}

func TestAppAttestMalformedData(t *testing.T) {
	f := makeFixture(t, true)
	for _, proof := range [][]byte{nil, {0xff}, bytes.Repeat([]byte{0}, MaxProofBytes+1), append(bytes.Clone(f.proof), 0)} {
		if _, err := f.verifier.Attestation(proof, f.keyID, f.hash); err == nil {
			t.Fatal("malformed attestation accepted")
		}
		if _, _, err := f.verifier.Assertion(proof, f.public, f.hash, 0); err == nil {
			t.Fatal("malformed assertion accepted")
		}
	}
	// Duplicate map keys must not select an attacker-controlled interpretation.
	if decoder.Unmarshal([]byte{0xa2, 0x61, 'x', 0x01, 0x61, 'x', 0x02}, new(map[string]any)) == nil {
		t.Fatal("duplicate CBOR key accepted")
	}
	for size := 0; size < 37; size++ {
		if _, err := f.verifier.authData(make([]byte, size), true); err == nil {
			t.Fatal("short auth data accepted")
		}
	}
}

func FuzzAppAttestParsers(f *testing.F) {
	f.Add([]byte{0xa0})
	f.Add([]byte{0xff})
	f.Add(make([]byte, 37))
	v := New(Policy{"TEST.app", "production"})
	f.Fuzz(func(t *testing.T, b []byte) {
		if len(b) > MaxProofBytes {
			return
		}
		_, _ = v.Attestation(b, "", [32]byte{})
		_, _, _ = v.Assertion(b, nil, [32]byte{}, 0)
		_, _ = v.authData(b, true)
	})
}
