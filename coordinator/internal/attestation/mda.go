// Package attestation — MDA (Managed Device Attestation) certificate chain
// verification.
//
// Apple's Managed Device Attestation allows MDM-enrolled devices to generate
// certificates containing device identity and security properties signed by
// Apple's Enterprise Attestation Root CA. This provides hardware-backed
// attestation that cannot be spoofed by a compromised OS.
//
// Two attestation paths exist:
//   1. ACME device-attest-01: OIDs in 1.2.840.113635.100.8.13.* (SIP, SecureBoot, Kext)
//   2. DeviceInformation DevicePropertiesAttestation: OIDs in 100.8.9.*, 100.8.10.*, 100.8.11.*
//      (Serial, UDID, SepOS version, OS version, freshness code)
//
// This module implements path 2 (DevicePropertiesAttestation) via MDM.
package attestation

import (
	"crypto/x509"
	"encoding/asn1"
	"encoding/pem"
	"fmt"
)

// Apple MDA OID constants — ACME device-attest-01 path (existing).
var (
	OIDSIPStatus        = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 13, 1}
	OIDSecureBootStatus = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 13, 2}
	OIDKextStatus       = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 13, 3}
)

// Apple MDA OID constants — DevicePropertiesAttestation path (MDM DeviceInformation).
var (
	OIDDeviceSerialNumber      = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 9, 1}
	OIDDeviceUDID              = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 9, 2}
	OIDSoftwareUpdateDeviceID  = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 9, 4}
	OIDOSVersion               = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 10, 1}
	OIDSepOSVersion            = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 10, 2}
	OIDLLBVersion              = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 10, 3}
	OIDFreshnessCode           = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 11, 1}
)

// Apple Enterprise Attestation Root CA (P-384, valid until 2047).
// Downloaded from https://www.apple.com/certificateauthority/
const appleEnterpriseAttestationRootCAPEM = `-----BEGIN CERTIFICATE-----
MIICJDCCAamgAwIBAgIUQsDCuyxyfFxeq/bxpm8frF15hzcwCgYIKoZIzj0EAwMw
UTEtMCsGA1UEAwwkQXBwbGUgRW50ZXJwcmlzZSBBdHRlc3RhdGlvbiBSb290IENB
MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzAeFw0yMjAyMTYxOTAx
MjRaFw00NzAyMjAwMDAwMDBaMFExLTArBgNVBAMMJEFwcGxlIEVudGVycHJpc2Ug
QXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UE
BhMCVVMwdjAQBgcqhkjOPQIBBgUrgQQAIgNiAAT6Jigq+Ps9Q4CoT8t8q+UnOe2p
oT9nRaUfGhBTbgvqSGXPjVkbYlIWYO+1zPk2Sz9hQ5ozzmLrPmTBgEWRcHjA2/y7
7GEicps9wn2tj+G89l3INNDKETdxSPPIZpPj8VmjQjBAMA8GA1UdEwEB/wQFMAMB
Af8wHQYDVR0OBBYEFPNqTQGd8muBpV5du+UIbVbi+d66MA4GA1UdDwEB/wQEAwIB
BjAKBggqhkjOPQQDAwNpADBmAjEA1xpWmTLSpr1VH4f8Ypk8f3jMUKYz4QPG8mL5
8m9sX/b2+eXpTv2pH4RZgJjucnbcAjEA4ZSB6S45FlPuS/u4pTnzoz632rA+xW/T
ZwFEh9bhKjJ+5VQ9/Do1os0u3LEkgN/r
-----END CERTIFICATE-----`

var appleEnterpriseAttestationRootCA *x509.Certificate

func init() {
	block, _ := pem.Decode([]byte(appleEnterpriseAttestationRootCAPEM))
	if block == nil {
		panic("attestation: failed to decode embedded Apple Enterprise Attestation Root CA PEM")
	}
	var err error
	appleEnterpriseAttestationRootCA, err = x509.ParseCertificate(block.Bytes)
	if err != nil {
		panic(fmt.Sprintf("attestation: failed to parse embedded Apple Root CA: %v", err))
	}
}

// MDAResult contains the parsed device properties from an MDA certificate.
type MDAResult struct {
	Valid bool

	// Device identity (from OIDs or subject).
	DeviceSerial string
	DeviceUDID   string

	// Security properties from ACME path OIDs (100.8.13.*).
	SIPEnabled        bool
	SecureBootEnabled bool
	ThirdPartyKexts   bool

	// Device properties from DevicePropertiesAttestation OIDs.
	OSVersion    string
	SepOSVersion string
	LLBVersion   string

	// Freshness code (hash of DeviceAttestationNonce if provided).
	FreshnessCode []byte

	Error string
}

// VerifyMDADeviceAttestation verifies a DevicePropertiesAttestation certificate
// chain (DER-encoded) against Apple's Enterprise Attestation Root CA.
//
// Returns attested device properties extracted from the leaf certificate OIDs.
// These properties are signed by Apple — a compromised OS cannot forge them.
func VerifyMDADeviceAttestation(certChainDER [][]byte) (*MDAResult, error) {
	if len(certChainDER) == 0 {
		return nil, fmt.Errorf("mda: empty certificate chain")
	}

	// Parse DER certificates.
	var certs []*x509.Certificate
	for i, der := range certChainDER {
		cert, err := x509.ParseCertificate(der)
		if err != nil {
			return nil, fmt.Errorf("mda: failed to parse certificate %d: %w", i, err)
		}
		certs = append(certs, cert)
	}

	leaf := certs[0]

	// Build verification chain.
	roots := x509.NewCertPool()
	roots.AddCert(appleEnterpriseAttestationRootCA)

	intermediates := x509.NewCertPool()
	for _, ic := range certs[1:] {
		intermediates.AddCert(ic)
	}

	opts := x509.VerifyOptions{
		Roots:         roots,
		Intermediates: intermediates,
		KeyUsages:     []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
	}

	// Verify the certificate chain against Apple's Root CA.
	// This is the critical security check — if this passes, Apple vouches
	// for every property encoded in the leaf certificate.
	if _, err := leaf.Verify(opts); err != nil {
		return &MDAResult{
			Error: fmt.Sprintf("Apple certificate chain verification failed: %v", err),
		}, nil
	}

	// Extract attested properties from leaf certificate OIDs.
	result := &MDAResult{Valid: true}

	// Serial from subject (standard X.509 field).
	result.DeviceSerial = leaf.Subject.SerialNumber

	for _, ext := range leaf.Extensions {
		switch {
		// Device identity OIDs (100.8.9.*)
		case ext.Id.Equal(OIDDeviceSerialNumber):
			result.DeviceSerial = parseStringOID(ext.Value)
		case ext.Id.Equal(OIDDeviceUDID):
			result.DeviceUDID = parseStringOID(ext.Value)

		// Device version OIDs (100.8.10.*)
		case ext.Id.Equal(OIDOSVersion):
			result.OSVersion = parseStringOID(ext.Value)
		case ext.Id.Equal(OIDSepOSVersion):
			result.SepOSVersion = parseStringOID(ext.Value)
		case ext.Id.Equal(OIDLLBVersion):
			result.LLBVersion = parseStringOID(ext.Value)

		// Freshness (100.8.11.*)
		case ext.Id.Equal(OIDFreshnessCode):
			result.FreshnessCode = ext.Value

		// ACME path OIDs (100.8.13.*) — may also be present
		case ext.Id.Equal(OIDSIPStatus):
			result.SIPEnabled = parseBoolOID(ext.Value)
		case ext.Id.Equal(OIDSecureBootStatus):
			result.SecureBootEnabled = parseBoolOID(ext.Value)
		case ext.Id.Equal(OIDKextStatus):
			result.ThirdPartyKexts = parseBoolOID(ext.Value)
		}
	}

	return result, nil
}

// VerifyMDACertChain verifies a PEM-encoded MDA certificate chain.
// Kept for backward compatibility with the ACME path.
func VerifyMDACertChain(certChainPEM []byte, appleRootCA *x509.Certificate) (*MDAResult, error) {
	certs, err := parsePEMCertificates(certChainPEM)
	if err != nil {
		return nil, fmt.Errorf("mda: failed to parse certificate chain: %w", err)
	}

	if len(certs) == 0 {
		return nil, fmt.Errorf("mda: empty certificate chain")
	}

	leaf := certs[0]
	intermediatesCerts := certs[1:]

	result := &MDAResult{}

	// When a root CA is provided, verify the certificate chain.
	// When nil, skip chain verification and just parse OIDs.
	if appleRootCA != nil {
		roots := x509.NewCertPool()
		roots.AddCert(appleRootCA)

		intPool := x509.NewCertPool()
		for _, ic := range intermediatesCerts {
			intPool.AddCert(ic)
		}

		opts := x509.VerifyOptions{
			Roots:         roots,
			Intermediates: intPool,
		}

		if _, err := leaf.Verify(opts); err != nil {
			result.Error = fmt.Sprintf("certificate chain verification failed: %v", err)
			return result, nil
		}
	}

	result.Valid = true
	result.DeviceSerial = leaf.Subject.SerialNumber

	for _, ext := range leaf.Extensions {
		switch {
		case ext.Id.Equal(OIDSIPStatus):
			result.SIPEnabled = parseBoolOID(ext.Value)
		case ext.Id.Equal(OIDSecureBootStatus):
			result.SecureBootEnabled = parseBoolOID(ext.Value)
		case ext.Id.Equal(OIDKextStatus):
			result.ThirdPartyKexts = parseBoolOID(ext.Value)
		case ext.Id.Equal(OIDDeviceSerialNumber):
			result.DeviceSerial = parseStringOID(ext.Value)
		case ext.Id.Equal(OIDDeviceUDID):
			result.DeviceUDID = parseStringOID(ext.Value)
		}
	}

	return result, nil
}

// GetAppleEnterpriseAttestationRootCA returns the embedded Apple Root CA.
func GetAppleEnterpriseAttestationRootCA() *x509.Certificate {
	return appleEnterpriseAttestationRootCA
}

// parsePEMCertificates parses a PEM-encoded certificate chain.
func parsePEMCertificates(pemData []byte) ([]*x509.Certificate, error) {
	var certs []*x509.Certificate
	rest := pemData
	for {
		var block *pem.Block
		block, rest = pem.Decode(rest)
		if block == nil {
			break
		}
		if block.Type != "CERTIFICATE" {
			continue
		}
		cert, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return nil, fmt.Errorf("failed to parse certificate: %w", err)
		}
		certs = append(certs, cert)
	}
	return certs, nil
}

// parseBoolOID attempts to parse an ASN.1-encoded boolean from an extension value.
func parseBoolOID(data []byte) bool {
	var val bool
	if _, err := asn1.Unmarshal(data, &val); err != nil {
		if len(data) > 0 {
			return data[len(data)-1] != 0
		}
		return false
	}
	return val
}

// parseStringOID attempts to parse an ASN.1-encoded UTF8String from an extension value.
func parseStringOID(data []byte) string {
	var val string
	if _, err := asn1.Unmarshal(data, &val); err != nil {
		// Fallback: try raw bytes as string.
		return string(data)
	}
	return val
}
