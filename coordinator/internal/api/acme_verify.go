package api

import (
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"fmt"
	"net/http"
	"net/url"
)

// ACMEVerificationResult contains the result of verifying a provider's
// ACME device-attest-01 client certificate.
type ACMEVerificationResult struct {
	Valid        bool
	SerialNumber string // CN from the cert (device serial)
	Issuer       string
	PublicKeyAlg string
	PublicKey    string // uncompressed P-256 point, base64 encoded
	Error        string
}

// extractAndVerifyClientCert reads the client certificate from nginx headers
// and verifies it against the step-ca root CA.
func (s *Server) extractAndVerifyClientCert(r *http.Request) *ACMEVerificationResult {
	if s.stepCARootCert == nil {
		return nil // ACME verification not configured
	}

	verifyStatus := r.Header.Get("X-SSL-Client-Verify")
	certEncoded := r.Header.Get("X-SSL-Client-Cert")
	clientDN := r.Header.Get("X-SSL-Client-DN")

	s.logger.Info("TLS client cert headers",
		"verify", verifyStatus,
		"cert_len", len(certEncoded),
		"dn", clientDN,
	)

	if certEncoded == "" || verifyStatus == "" {
		return nil // no client cert presented
	}

	result := &ACMEVerificationResult{}

	if verifyStatus != "SUCCESS" {
		result.Error = "nginx client cert verification failed: " + verifyStatus
		return result
	}

	// nginx URL-encodes the PEM cert
	certPEM, err := url.QueryUnescape(certEncoded)
	if err != nil {
		result.Error = "failed to decode client cert: " + err.Error()
		return result
	}

	// Parse the PEM certificate
	block, _ := pem.Decode([]byte(certPEM))
	if block == nil {
		result.Error = "invalid PEM in client cert"
		return result
	}

	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		result.Error = "failed to parse client cert: " + err.Error()
		return result
	}

	// Verify against step-ca root CA
	roots := x509.NewCertPool()
	roots.AddCert(s.stepCARootCert)

	// Add intermediate if we have it
	if s.stepCAIntermediateCert != nil {
		intermediates := x509.NewCertPool()
		intermediates.AddCert(s.stepCAIntermediateCert)
		_, err = cert.Verify(x509.VerifyOptions{
			Roots:         roots,
			Intermediates: intermediates,
			KeyUsages:     []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
		})
	} else {
		_, err = cert.Verify(x509.VerifyOptions{
			Roots:     roots,
			KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
		})
	}

	if err != nil {
		result.Error = "client cert chain verification failed: " + err.Error()
		return result
	}

	result.Valid = true
	result.SerialNumber = cert.Subject.CommonName
	result.Issuer = cert.Issuer.CommonName
	result.PublicKeyAlg = cert.PublicKeyAlgorithm.String()
	result.PublicKey, err = encodeP256PublicKey(cert.PublicKey)
	if err != nil {
		result.Valid = false
		result.Error = err.Error()
		return result
	}

	s.logger.Info("ACME client cert verified",
		"serial", result.SerialNumber,
		"issuer", result.Issuer,
		"key_alg", result.PublicKeyAlg,
		"client_dn", clientDN,
	)

	return result
}

func encodeP256PublicKey(rawKey any) (string, error) {
	pubKey, ok := rawKey.(*ecdsa.PublicKey)
	if !ok {
		return "", fmt.Errorf("client cert public key was %T, expected ECDSA P-256", rawKey)
	}
	if pubKey.Curve == nil || pubKey.Curve.Params().BitSize != 256 {
		return "", fmt.Errorf("client cert public key was not P-256")
	}

	xBytes := pubKey.X.Bytes()
	yBytes := pubKey.Y.Bytes()
	encoded := make([]byte, 64)
	copy(encoded[32-len(xBytes):32], xBytes)
	copy(encoded[64-len(yBytes):64], yBytes)
	return base64.StdEncoding.EncodeToString(encoded), nil
}
