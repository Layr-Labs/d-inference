package profilesign

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"log/slog"
	"math/big"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/smallstep/pkcs7"
	pkcs12 "software.sslmate.com/src/go-pkcs12"
)

// makeTestP12 builds an ephemeral self-signed code-signing identity and returns
// it as a DER PKCS#12 bundle plus the password used to encrypt it.
func makeTestP12(t *testing.T, cn, org string, notBefore, notAfter time.Time) ([]byte, string) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			CommonName:   cn,
			Organization: []string{org},
		},
		NotBefore:             notBefore,
		NotAfter:              notAfter,
		KeyUsage:              x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageCodeSigning},
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create certificate: %v", err)
	}
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatalf("parse certificate: %v", err)
	}
	const password = "test-password"
	p12, err := pkcs12.Modern.Encode(key, cert, nil, password)
	if err != nil {
		t.Fatalf("encode pkcs12: %v", err)
	}
	return p12, password
}

func TestSignerSignProducesAttachedCMS(t *testing.T) {
	now := time.Now()
	p12, password := makeTestP12(t, "Darkbloom Test Signer", "Darkbloom", now.Add(-time.Hour), now.Add(24*time.Hour))

	signer, err := NewSigner(p12, password)
	if err != nil {
		t.Fatalf("NewSigner: %v", err)
	}

	if signer.CommonName() != "Darkbloom Test Signer" {
		t.Errorf("CommonName = %q, want %q", signer.CommonName(), "Darkbloom Test Signer")
	}
	if signer.Organization() != "Darkbloom" {
		t.Errorf("Organization = %q, want %q", signer.Organization(), "Darkbloom")
	}
	if signer.Expired(now) {
		t.Error("freshly minted cert reported as expired")
	}

	profile := []byte(`<?xml version="1.0"?><plist><dict><key>x</key><string>y</string></dict></plist>`)
	signed, err := signer.Sign(profile)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}
	if len(signed) <= len(profile) {
		t.Fatalf("signed output (%d bytes) not larger than input (%d bytes)", len(signed), len(profile))
	}

	// The output must be a parseable CMS SignedData whose encapsulated content is
	// byte-identical to the original profile (attached, not detached).
	p7, err := pkcs7.Parse(signed)
	if err != nil {
		t.Fatalf("signed output is not valid PKCS7/CMS: %v", err)
	}
	if string(p7.Content) != string(profile) {
		t.Errorf("encapsulated content does not match original profile\n got: %q\nwant: %q", p7.Content, profile)
	}
	if got := p7.GetOnlySigner(); got == nil || got.Subject.CommonName != "Darkbloom Test Signer" {
		t.Errorf("unexpected signer cert: %+v", got)
	}
}

// TestSignerSignatureVerifies confirms the produced CMS signature is
// cryptographically valid over the content, using a trust pool seeded with the
// (self-signed) signing cert as root.
func TestSignerSignatureVerifies(t *testing.T) {
	now := time.Now()
	p12, password := makeTestP12(t, "Darkbloom Verify Signer", "Darkbloom", now.Add(-time.Hour), now.Add(24*time.Hour))
	signer, err := NewSigner(p12, password)
	if err != nil {
		t.Fatalf("NewSigner: %v", err)
	}

	profile := []byte(`<?xml version="1.0"?><plist><dict><key>k</key><string>v</string></dict></plist>`)
	signed, err := signer.Sign(profile)
	if err != nil {
		t.Fatalf("Sign: %v", err)
	}
	p7, err := pkcs7.Parse(signed)
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}

	pool := x509.NewCertPool()
	pool.AddCert(p7.GetOnlySigner()) // self-signed signer doubles as its own root
	if err := p7.VerifyWithChain(pool); err != nil {
		t.Errorf("CMS signature failed cryptographic verification: %v", err)
	}
}

// TestNewSignerReordersChain confirms a misordered (or root-containing) CA bundle
// is normalized to issuer order with the root dropped, so AddSignerChain accepts
// it regardless of bag order.
func TestNewSignerReordersChain(t *testing.T) {
	now := time.Now()

	// Build root -> intermediate -> leaf.
	rootKey, _ := rsa.GenerateKey(rand.Reader, 2048)
	rootTmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Test Root"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(72 * time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}
	rootDER, _ := x509.CreateCertificate(rand.Reader, rootTmpl, rootTmpl, &rootKey.PublicKey, rootKey)
	root, _ := x509.ParseCertificate(rootDER)

	intKey, _ := rsa.GenerateKey(rand.Reader, 2048)
	intTmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(2),
		Subject:               pkix.Name{CommonName: "Test Intermediate"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(48 * time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}
	intDER, _ := x509.CreateCertificate(rand.Reader, intTmpl, root, &intKey.PublicKey, rootKey)
	intermediate, _ := x509.ParseCertificate(intDER)

	leafKey, _ := rsa.GenerateKey(rand.Reader, 2048)
	leafTmpl := &x509.Certificate{
		SerialNumber: big.NewInt(3),
		Subject:      pkix.Name{CommonName: "Test Leaf", Organization: []string{"Darkbloom"}},
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageCodeSigning},
	}
	leafDER, _ := x509.CreateCertificate(rand.Reader, leafTmpl, intermediate, &leafKey.PublicKey, intKey)
	leaf, _ := x509.ParseCertificate(leafDER)

	// Misordered bundle: root first, then intermediate.
	p12, err := pkcs12.Modern.Encode(leafKey, leaf, []*x509.Certificate{root, intermediate}, "pw")
	if err != nil {
		t.Fatalf("encode pkcs12: %v", err)
	}
	signer, err := NewSigner(p12, "pw")
	if err != nil {
		t.Fatalf("NewSigner: %v", err)
	}

	// Chain should be exactly [intermediate] (issuer order, root dropped).
	if len(signer.chain) != 1 || signer.chain[0].Subject.CommonName != "Test Intermediate" {
		var names []string
		for _, c := range signer.chain {
			names = append(names, c.Subject.CommonName)
		}
		t.Fatalf("expected ordered chain [Test Intermediate], got %v", names)
	}

	// And signing must still succeed (AddSignerChain accepts the ordered chain).
	if _, err := signer.Sign([]byte(`<?xml version="1.0"?><plist></plist>`)); err != nil {
		t.Errorf("Sign with reordered chain failed: %v", err)
	}
}

func TestSignerExpired(t *testing.T) {
	now := time.Now()
	// Already-expired certificate.
	p12, password := makeTestP12(t, "Old Signer", "Darkbloom", now.Add(-48*time.Hour), now.Add(-24*time.Hour))
	signer, err := NewSigner(p12, password)
	if err != nil {
		t.Fatalf("NewSigner: %v", err)
	}
	if !signer.Expired(now) {
		t.Error("expected expired cert to report Expired() == true")
	}
}

func TestNewSignerWrongPassword(t *testing.T) {
	now := time.Now()
	p12, _ := makeTestP12(t, "Signer", "Darkbloom", now.Add(-time.Hour), now.Add(time.Hour))
	if _, err := NewSigner(p12, "wrong-password"); err == nil {
		t.Error("expected error decoding pkcs12 with wrong password")
	}
}

// TestLoadFromEnvExpiredCertDisablesSigning is a regression for the P2 finding:
// an expired/not-yet-valid signing cert must degrade to unsigned (nil signer)
// rather than stamping an untrusted CMS signature.
func TestLoadFromEnvExpiredCertDisablesSigning(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	now := time.Now()
	p12, password := makeTestP12(t, "Expired Signer", "Darkbloom", now.Add(-48*time.Hour), now.Add(-time.Hour))

	t.Setenv("PROFILE_SIGNING_P12_PATH", "")
	t.Setenv("PROFILE_SIGNING_P12_B64", base64.StdEncoding.EncodeToString(p12))
	t.Setenv("PROFILE_SIGNING_P12_PASSWORD", password)

	if s := LoadFromEnv(logger); s != nil {
		t.Error("expected nil signer (degrade to unsigned) for an expired signing certificate")
	}
}

func TestLoadFromEnv(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))

	// Nothing configured -> nil, no error, degrade to unsigned.
	t.Run("unconfigured", func(t *testing.T) {
		t.Setenv("PROFILE_SIGNING_P12_B64", "")
		t.Setenv("PROFILE_SIGNING_P12_PATH", "")
		t.Setenv("PROFILE_SIGNING_P12_PASSWORD", "")
		if s := LoadFromEnv(logger); s != nil {
			t.Error("expected nil signer when unconfigured")
		}
	})

	now := time.Now()
	p12, password := makeTestP12(t, "Env Signer", "Darkbloom", now.Add(-time.Hour), now.Add(24*time.Hour))

	t.Run("base64_std", func(t *testing.T) {
		t.Setenv("PROFILE_SIGNING_P12_PATH", "")
		t.Setenv("PROFILE_SIGNING_P12_B64", base64.StdEncoding.EncodeToString(p12))
		t.Setenv("PROFILE_SIGNING_P12_PASSWORD", password)
		s := LoadFromEnv(logger)
		if s == nil {
			t.Fatal("expected signer from base64 env")
		}
		if s.CommonName() != "Env Signer" {
			t.Errorf("CommonName = %q", s.CommonName())
		}
	})

	t.Run("base64_urlsafe", func(t *testing.T) {
		t.Setenv("PROFILE_SIGNING_P12_PATH", "")
		t.Setenv("PROFILE_SIGNING_P12_B64", base64.RawURLEncoding.EncodeToString(p12))
		t.Setenv("PROFILE_SIGNING_P12_PASSWORD", password)
		if s := LoadFromEnv(logger); s == nil {
			t.Fatal("expected signer from URL-safe base64 env")
		}
	})

	t.Run("path", func(t *testing.T) {
		dir := t.TempDir()
		p12Path := dir + "/signer.p12"
		if err := os.WriteFile(p12Path, p12, 0o600); err != nil {
			t.Fatal(err)
		}
		t.Setenv("PROFILE_SIGNING_P12_B64", "")
		t.Setenv("PROFILE_SIGNING_P12_PATH", p12Path)
		t.Setenv("PROFILE_SIGNING_P12_PASSWORD", password)
		if s := LoadFromEnv(logger); s == nil {
			t.Fatal("expected signer from path env")
		}
	})

	t.Run("bad_base64", func(t *testing.T) {
		t.Setenv("PROFILE_SIGNING_P12_PATH", "")
		t.Setenv("PROFILE_SIGNING_P12_B64", "!!!not base64!!!")
		if s := LoadFromEnv(logger); s != nil {
			t.Error("expected nil signer for invalid base64")
		}
	})
}

// Guard: the encapsulated content of a signed profile must remain a plist the
// installer can read (smoke check on the round-trip used by enroll.go).
func TestSignedProfileRoundTrip(t *testing.T) {
	now := time.Now()
	p12, password := makeTestP12(t, "Darkbloom", "Darkbloom", now.Add(-time.Hour), now.Add(time.Hour))
	signer, err := NewSigner(p12, password)
	if err != nil {
		t.Fatal(err)
	}
	profile := []byte(`<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict></dict></plist>`)
	signed, err := signer.Sign(profile)
	if err != nil {
		t.Fatal(err)
	}
	p7, err := pkcs7.Parse(signed)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(p7.Content), `<?xml version="1.0"`) {
		t.Errorf("decoded content is not a plist: %q", p7.Content)
	}
}
