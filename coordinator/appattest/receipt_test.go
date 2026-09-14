package appattest

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"math/big"
	"testing"
	"time"

	"github.com/smallstep/pkcs7"
)

func TestReceiptValidationUsesIndependentRootAndChecksBindings(t *testing.T) {
	now := time.Now().UTC()
	signer, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "test receipt root"}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &signer.PublicKey, signer)
	if err != nil {
		t.Fatal(err)
	}
	cert, _ := x509.ParseCertificate(der)
	roots := x509.NewCertPool()
	roots.AddCert(cert)
	device, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	public := elliptic.Marshal(device.Curve, device.X, device.Y)
	pkixKey, _ := x509.MarshalPKIXPublicKey(&device.PublicKey)
	hash := sha256.Sum256([]byte("client data"))
	type attr struct {
		Type    int
		Version int
		Value   []byte
	}
	attrs := []attr{{2, 1, []byte("TEST.app")}, {3, 1, pkixKey}, {4, 1, hash[:]}, {6, 1, []byte("ATTEST")}, {12, 1, []byte(now.Format(time.RFC3339Nano))}, {21, 1, []byte(now.Add(time.Hour).Format(time.RFC3339Nano))}}
	sign := func(fields []attr) []byte {
		t.Helper()
		content, e := asn1.MarshalWithParams(fields, "set")
		if e != nil {
			t.Fatal(e)
		}
		sd, e := pkcs7.NewSignedData(content)
		if e != nil {
			t.Fatal(e)
		}
		sd.SetDigestAlgorithm(pkcs7.OIDDigestAlgorithmSHA256)
		if e = sd.AddSigner(cert, signer, pkcs7.SignerInfoConfig{}); e != nil {
			t.Fatal(e)
		}
		raw, e := sd.Finish()
		if e != nil {
			t.Fatal(e)
		}
		return raw
	}
	raw := sign(attrs)
	if _, err = verifyReceipt(raw, public, "TEST.app", hash, now, roots); err != nil {
		t.Fatal(err)
	}
	if _, err = VerifyReceipt(raw, public, "TEST.app", hash, now); err == nil {
		t.Fatal("production accepted test root")
	}
	for _, c := range []struct {
		name, app string
		hash      [32]byte
		at        time.Time
	}{
		{"wrong app", "OTHER.app", hash, now}, {"wrong hash", "TEST.app", [32]byte{}, now}, {"stale", "TEST.app", hash, now.Add(6 * time.Minute)},
	} {
		t.Run(c.name, func(t *testing.T) {
			if _, err := verifyReceipt(raw, public, c.app, c.hash, c.at, roots); err == nil {
				t.Fatal("invalid receipt accepted")
			}
		})
	}
	if _, err = verifyReceipt(sign(append(attrs, attrs[0])), public, "TEST.app", hash, now, roots); err == nil {
		t.Fatal("duplicate fields accepted")
	}
	raw[len(raw)-2] ^= 1
	if _, err = verifyReceipt(raw, public, "TEST.app", hash, now, roots); err == nil {
		t.Fatal("tampering accepted")
	}
}
