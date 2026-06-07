// Package profilesign CMS-signs Apple configuration profiles (.mobileconfig) so
// macOS/iOS show them as signed/trusted at install time instead of "Unsigned".
//
// Signing is optional and install-time trust only: it does not affect the
// SCEP/MDM/ACME attestation chain inside the profile, and a missing or broken
// identity must degrade to serving unsigned (never block enrollment). The trust
// shown depends solely on the signing cert chaining to a CA already on the
// device — i.e. a code-signing cert such as an Apple "Developer ID Application"
// (chains to the Apple Root CA on every Mac); include the issuing intermediate
// in the bundle so the device can build the full path.
package profilesign

import (
	"bytes"
	"crypto"
	"crypto/x509"
	"encoding/base64"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"time"

	"github.com/smallstep/pkcs7"
	pkcs12 "software.sslmate.com/src/go-pkcs12"
)

// expiryWarnWindow is how far before NotAfter we start warning at startup that
// the signing certificate needs rotation.
const expiryWarnWindow = 30 * 24 * time.Hour

// Signer holds a loaded code-signing identity used to CMS-sign configuration
// profiles. It is immutable after construction and safe for concurrent use:
// Sign performs no mutation of the stored key material.
type Signer struct {
	leaf  *x509.Certificate
	key   crypto.PrivateKey
	chain []*x509.Certificate // issuing intermediate(s) to embed; excludes the root
}

// NewSigner builds a Signer from a DER-encoded PKCS#12 (.p12) bundle. The bundle
// must contain exactly one private key and its leaf certificate; any additional
// certificates are treated as the intermediate chain and embedded in the
// signature so devices can build a path to a trusted root.
func NewSigner(p12 []byte, password string) (*Signer, error) {
	key, leaf, caCerts, err := pkcs12.DecodeChain(p12, password)
	if err != nil {
		return nil, fmt.Errorf("decode pkcs12 bundle: %w", err)
	}
	if leaf == nil {
		return nil, fmt.Errorf("pkcs12 bundle has no leaf certificate")
	}
	if key == nil {
		return nil, fmt.Errorf("pkcs12 bundle has no private key")
	}
	return &Signer{leaf: leaf, key: key, chain: orderChain(leaf, caCerts)}, nil
}

// orderChain returns the intermediate certificates from pool ordered from the
// leaf's direct issuer upward, excluding any self-signed root (devices already
// trust the root; embedding it is unnecessary). pkcs12.DecodeChain returns CA
// certs in bag order, which is not guaranteed to be issuer order — and
// pkcs7.AddSignerChain's partial-chain check rejects a misordered chain. This
// makes signing robust regardless of how the bundle was assembled. If the leaf's
// issuer can't be found in pool (unexpected bundle), it falls back to returning
// pool unchanged so no needed intermediate is silently dropped.
func orderChain(leaf *x509.Certificate, pool []*x509.Certificate) []*x509.Certificate {
	remaining := make([]*x509.Certificate, len(pool))
	copy(remaining, pool)

	var ordered []*x509.Certificate
	current := leaf
	for {
		idx := -1
		for i, c := range remaining {
			if c == nil {
				continue
			}
			if bytes.Equal(current.RawIssuer, c.RawSubject) {
				idx = i
				break
			}
		}
		if idx == -1 {
			break
		}
		next := remaining[idx]
		remaining[idx] = nil
		// Stop at (and omit) a self-signed root; also guards against loops.
		if bytes.Equal(next.RawSubject, next.RawIssuer) {
			break
		}
		ordered = append(ordered, next)
		current = next
	}

	if len(ordered) == 0 && len(pool) > 0 {
		return pool
	}
	return ordered
}

// Sign wraps the profile bytes in a CMS SignedData structure with the content
// attached (as Apple's profile installer requires) and returns the DER bytes.
// The digest is SHA-256.
func (s *Signer) Sign(profile []byte) ([]byte, error) {
	sd, err := pkcs7.NewSignedData(profile)
	if err != nil {
		return nil, fmt.Errorf("new signed data: %w", err)
	}
	sd.SetDigestAlgorithm(pkcs7.OIDDigestAlgorithmSHA256)
	if err := sd.AddSignerChain(s.leaf, s.key, s.chain, pkcs7.SignerInfoConfig{}); err != nil {
		return nil, fmt.Errorf("add signer: %w", err)
	}
	// IMPORTANT: do NOT call sd.Detach(); the profile content must remain
	// encapsulated inside the SignedData for a .mobileconfig.
	der, err := sd.Finish()
	if err != nil {
		return nil, fmt.Errorf("finish signed data: %w", err)
	}
	return der, nil
}

// CommonName is the signer leaf certificate's CN — the identity macOS shows as
// "Signed by" on the install sheet.
func (s *Signer) CommonName() string { return s.leaf.Subject.CommonName }

// Organization is the signer leaf certificate's first O value, if any.
func (s *Signer) Organization() string {
	if len(s.leaf.Subject.Organization) > 0 {
		return s.leaf.Subject.Organization[0]
	}
	return ""
}

// NotAfter is the signer certificate's expiry instant.
func (s *Signer) NotAfter() time.Time { return s.leaf.NotAfter }

// Expired reports whether the signing certificate is outside its validity window
// at time now (either not yet valid or already expired).
func (s *Signer) Expired(now time.Time) bool {
	return now.Before(s.leaf.NotBefore) || now.After(s.leaf.NotAfter)
}

// LoadFromEnv builds a Signer from the environment, returning nil (no error) when
// unconfigured or misconfigured so the caller degrades to serving unsigned
// profiles rather than aborting startup. Bundle source (first match wins):
//
//	PROFILE_SIGNING_P12_B64       base64 (std or URL-safe) DER PKCS#12 bundle
//	PROFILE_SIGNING_P12_PATH      path to a DER PKCS#12 bundle
//	PROFILE_SIGNING_P12_PASSWORD  bundle password (may be empty)
//
// The base64 form mirrors MDM_PUSH_P12_B64 for the same KMS pipeline.
func LoadFromEnv(logger *slog.Logger) *Signer {
	b64 := strings.TrimSpace(os.Getenv("PROFILE_SIGNING_P12_B64"))
	path := strings.TrimSpace(os.Getenv("PROFILE_SIGNING_P12_PATH"))
	password := os.Getenv("PROFILE_SIGNING_P12_PASSWORD")

	var raw []byte
	switch {
	case b64 != "":
		dec, err := decodeBase64Flexible(b64)
		if err != nil {
			logger.Error("profile signing disabled: PROFILE_SIGNING_P12_B64 is not valid base64", "error", err)
			return nil
		}
		raw = dec
	case path != "":
		data, err := os.ReadFile(path)
		if err != nil {
			logger.Error("profile signing disabled: cannot read PROFILE_SIGNING_P12_PATH", "path", path, "error", err)
			return nil
		}
		raw = data
	default:
		return nil
	}

	signer, err := NewSigner(raw, password)
	if err != nil {
		logger.Error("profile signing disabled: failed to load signing identity", "error", err)
		return nil
	}

	// Refuse to sign with an invalid cert. Stamping a CMS signature with an
	// expired/not-yet-valid certificate is worse than serving unsigned: macOS
	// shows the profile as signed-but-untrusted and keeps breaking installs until
	// the process is restarted with a rotated identity. Degrade to unsigned.
	if signer.Expired(time.Now()) {
		logger.Error("profile signing disabled: signing certificate is expired or not yet valid — serving unsigned instead of an untrusted signature",
			"signer_cn", signer.CommonName(),
			"not_before", signer.leaf.NotBefore.Format(time.RFC3339),
			"not_after", signer.NotAfter().Format(time.RFC3339),
		)
		return nil
	}

	logger.Info("configuration-profile signing enabled",
		"signer_cn", signer.CommonName(),
		"signer_org", signer.Organization(),
		"not_after", signer.NotAfter().Format(time.RFC3339),
		"chain_len", len(signer.chain),
	)
	if time.Until(signer.NotAfter()) < expiryWarnWindow {
		logger.Warn("profile signing certificate expires soon — plan rotation",
			"not_after", signer.NotAfter().Format(time.RFC3339),
			"days_left", int(time.Until(signer.NotAfter()).Hours()/24),
		)
	}
	return signer
}

// decodeBase64Flexible accepts standard and URL-safe base64, with or without
// padding (matching the URL-safe convention used for MDM_PUSH_P12_B64 in deploy).
func decodeBase64Flexible(s string) ([]byte, error) {
	s = strings.TrimSpace(s)
	for _, enc := range []*base64.Encoding{
		base64.StdEncoding,
		base64.RawStdEncoding,
		base64.URLEncoding,
		base64.RawURLEncoding,
	} {
		if dec, err := enc.DecodeString(s); err == nil {
			return dec, nil
		}
	}
	return nil, fmt.Errorf("not valid base64 (standard or URL-safe)")
}
