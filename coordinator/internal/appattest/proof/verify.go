// Package proof parses and verifies App Attest evidence without trust mutation.
// Trust anchors and certificate time policy belong to its caller.
package proof

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/x509"
	"encoding/asn1"
	"encoding/base64"
	"errors"
	"time"

	"github.com/fxamacker/cbor/v2"
)

const MaxProofBytes = 32 * 1024
const VerifierVersion = "mac-shadow-v7"

type Policy struct {
	AppID       string
	Environment string
}

type Key struct {
	PublicKey          []byte
	BundleVersion      string
	ValidationCategory *uint32
	CodeDirectoryHash  []byte
	CodeDirectoryType  *uint8
}

type CoreVerifier struct {
	policy Policy
	roots  *x509.CertPool
	now    func() time.Time
}

// Config supplies explicit trust and time policy. The public service boundary
// always supplies Apple's pinned roots; nil never means system trust roots.
type Config struct {
	Policy Policy
	Roots  *x509.CertPool
	Now    func() time.Time
}

func New(cfg Config) *CoreVerifier {
	if cfg.Roots == nil || cfg.Now == nil {
		panic("App Attest proof verifier requires roots and clock")
	}
	return &CoreVerifier{policy: cfg.Policy, roots: cfg.Roots.Clone(), now: cfg.Now}
}

// Errors are closed codes: never forward decoder errors containing untrusted bytes to logs.
func invalid(code string) error { return errors.New(code) }

var decoder = func() cbor.DecMode {
	m, err := (cbor.DecOptions{DupMapKey: cbor.DupMapKeyEnforcedAPF, MaxNestedLevels: 8,
		MaxArrayElements: 16, MaxMapPairs: 16, IndefLength: cbor.IndefLengthForbidden,
		TagsMd: cbor.TagsForbidden}).DecMode()
	if err != nil {
		panic(err)
	}
	return m
}()

type AttestationObject struct {
	Format    string `cbor:"fmt"`
	Statement struct {
		Certificates [][]byte `cbor:"x5c"`
		Receipt      []byte   `cbor:"receipt"`
	} `cbor:"attStmt"`
	AuthData []byte `cbor:"authData"`
}

// DecodeAttestation bounds and decodes the envelope without authenticating it.
// Receipt extraction deliberately does not require an attestation format.
func DecodeAttestation(proof []byte) (*AttestationObject, error) {
	var a AttestationObject
	if len(proof) == 0 || len(proof) > MaxProofBytes || decoder.Unmarshal(proof, &a) != nil {
		return nil, invalid("malformed_attestation")
	}
	return &a, nil
}

func (v *CoreVerifier) Attestation(proof []byte, keyID string, clientHash [32]byte) (*Key, error) {
	a, err := DecodeAttestation(proof)
	if err != nil || a.Format != "apple-appattest" {
		return nil, invalid("malformed_attestation")
	}
	if len(a.Statement.Certificates) < 2 || len(a.Statement.Certificates) > 4 {
		return nil, invalid("certificate_chain")
	}
	leaf, err := x509.ParseCertificate(a.Statement.Certificates[0])
	if err != nil {
		return nil, invalid("certificate_chain")
	}
	intermediates := x509.NewCertPool()
	for _, der := range a.Statement.Certificates[1:] {
		cert, err := x509.ParseCertificate(der)
		if err != nil {
			return nil, invalid("certificate_chain")
		}
		intermediates.AddCert(cert)
	}
	if _, err := leaf.Verify(x509.VerifyOptions{Roots: v.roots, Intermediates: intermediates, CurrentTime: v.now(), KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny}}); err != nil {
		return nil, invalid("certificate_chain")
	}
	public, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok || public.Curve != elliptic.P256() {
		return nil, invalid("public_key")
	}
	encoded := elliptic.Marshal(public.Curve, public.X, public.Y)
	id := sha256.Sum256(encoded)
	claimed, err := base64.StdEncoding.DecodeString(keyID)
	if err != nil || base64.StdEncoding.EncodeToString(claimed) != keyID || !bytes.Equal(claimed, id[:]) {
		return nil, invalid("key_id")
	}
	nonce := CompositeHash(a.AuthData, clientHash)
	if !bytes.Equal(extensionOctets(leaf, asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 2}), nonce[:]) {
		return nil, invalid("nonce")
	}
	// Apple requires this exact access policy, not a provider's SIP self-report.
	acl, _ := base64.StdEncoding.DecodeString("MEAMAjExMDowCQwCb2uhAwEB/zAJDAJvYaEDAQH/MAsMBG9kZWyhAwEB/zAVDARvc2duoAYMBHJzZWMwBaYDAgEB")
	if !bytes.Equal(extensionOctets(leaf, asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 6}), acl) {
		return nil, invalid("mac_acl")
	}
	meta, err := ParseAuthenticator(v.policy.AppID, a.AuthData, true)
	if err != nil {
		return nil, err
	}
	if meta.counter != 0 || !bytes.Equal(meta.credentialID, id[:]) {
		return nil, invalid("credential")
	}
	expected := []byte("appattestdevelop")
	if v.policy.Environment == "production" {
		expected = append([]byte("appattest"), make([]byte, 7)...)
	} else if v.policy.Environment != "development" {
		return nil, invalid("environment")
	}
	if !bytes.Equal(meta.aaguid, expected) {
		return nil, invalid("environment")
	}
	if !bytes.Equal(meta.publicKey, encoded) {
		return nil, invalid("credential_key")
	}
	return &Key{PublicKey: encoded, BundleVersion: meta.version, ValidationCategory: meta.ValidationCategory, CodeDirectoryHash: meta.codeHash, CodeDirectoryType: meta.codeType}, nil
}

// Assertion verifies a fresh transcript signed by the previously attested key.
// Counter persistence and challenge ownership are performed atomically by the caller.
func (v *CoreVerifier) Assertion(proof, publicKey []byte, clientHash [32]byte, previous uint32) (uint32, *Key, error) {
	var a struct {
		Signature []byte `cbor:"signature"`
		AuthData  []byte `cbor:"authenticatorData"`
	}
	if len(proof) == 0 || len(proof) > MaxProofBytes || decoder.Unmarshal(proof, &a) != nil {
		return 0, nil, invalid("malformed_assertion")
	}
	x, y := elliptic.Unmarshal(elliptic.P256(), publicKey)
	if x == nil {
		return 0, nil, invalid("public_key")
	}
	nonce := CompositeHash(a.AuthData, clientHash)
	// Apple's assertion is ES256 over the nonce as a message. VerifyASN1
	// accepts an already-hashed digest, so hash that nonce once more here.
	// Attestation certificate nonces above retain the single composite hash.
	signatureHash := sha256.Sum256(nonce[:])
	if !ecdsa.VerifyASN1(&ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}, signatureHash[:], a.Signature) {
		return 0, nil, invalid("signature")
	}
	meta, err := ParseAuthenticator(v.policy.AppID, a.AuthData, false)
	if err != nil {
		return 0, nil, err
	}
	if meta.counter <= previous {
		return 0, nil, invalid("counter_replay")
	}
	return meta.counter, &Key{BundleVersion: meta.version, ValidationCategory: meta.ValidationCategory, CodeDirectoryHash: meta.codeHash, CodeDirectoryType: meta.codeType}, nil
}

// CompositeHash binds the complete authenticator bytes to the client transcript.
func CompositeHash(auth []byte, hash [32]byte) [32]byte {
	h := sha256.New()
	h.Write(auth)
	h.Write(hash[:])
	var d [32]byte
	copy(d[:], h.Sum(nil))
	return d
}

// Apple wraps extension values in a SEQUENCE and an explicit context tag.
func extensionOctets(cert *x509.Certificate, oid asn1.ObjectIdentifier) []byte {
	for _, ext := range cert.Extensions {
		if ext.Id.Equal(oid) {
			b := ext.Value
			for depth := 0; depth < 3; depth++ {
				var value asn1.RawValue
				rest, err := asn1.Unmarshal(b, &value)
				if err != nil || len(rest) != 0 {
					return nil
				}
				if value.Class == 0 && value.Tag == asn1.TagOctetString && !value.IsCompound {
					return value.Bytes
				}
				if !(value.IsCompound && ((value.Class == 0 && value.Tag == asn1.TagSequence) || value.Class == 2)) {
					return nil
				}
				b = value.Bytes
			}
		}
	}
	return nil
}
