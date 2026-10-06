// Package attestation — MDA (Managed Device Attestation) certificate chain
// verification.
//
// Apple's Managed Device Attestation allows MDM-enrolled devices to generate
// certificates containing device identity and security properties signed by
// Apple's Enterprise Attestation Root CA. This provides hardware-backed
// attestation that cannot be spoofed by a compromised OS.
//
// Two attestation paths exist:
//  1. Device-attest OID set: 1.2.840.113635.100.8.13.* (SIP, SecureBoot, Kext)
//  2. DeviceInformation DevicePropertiesAttestation: OIDs in 100.8.9.*, 100.8.10.*, 100.8.11.*
//     (Serial, UDID, SepOS version, OS version, freshness code)
//
// This module implements path 2 (DevicePropertiesAttestation) via MDM.
package attestation

import (
	"crypto/x509"
	"encoding/asn1"
	"encoding/pem"
	"errors"
	"fmt"
	"sync"

	attestationwire "github.com/eigeninference/d-inference/coordinator/internal/attestation/wire"
)

// Apple MDA OID constants — device-attest OID set (100.8.13.*).
var (
	OIDSIPStatus        = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 13, 1}
	OIDSecureBootStatus = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 13, 2}
	OIDKextStatus       = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 13, 3}
)

// Apple MDA OID constants — DevicePropertiesAttestation path (MDM DeviceInformation).
var (
	OIDDeviceSerialNumber     = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 9, 1}
	OIDDeviceUDID             = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 9, 2}
	OIDSoftwareUpdateDeviceID = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 9, 4}
	OIDOSVersion              = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 10, 1}
	OIDSepOSVersion           = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 10, 2}
	OIDLLBVersion             = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 10, 3}
	OIDFreshnessCode          = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 11, 1}
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

// verifyRoot is the trust anchor MDA certificate chains are verified against. In
// production it is the embedded Apple Enterprise Attestation Root CA (set in
// init). Tests swap it via OverrideRootCAForTest to exercise the verification and
// reuse paths with a chain signed by a CA they control — Apple's private key is,
// of course, unavailable to tests. Guarded by verifyRootMu.
var (
	verifyRootMu sync.RWMutex
	verifyRoot   *x509.Certificate
)

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
	verifyRoot = appleEnterpriseAttestationRootCA
}

// currentVerifyRoot returns the active MDA trust anchor (Apple's embedded root in
// production).
func currentVerifyRoot() *x509.Certificate {
	verifyRootMu.RLock()
	defer verifyRootMu.RUnlock()
	return verifyRoot
}

// OverrideRootCAForTest swaps the MDA trust anchor and returns a restore func.
// TEST-ONLY: production always verifies against the embedded Apple Enterprise
// Attestation Root CA. Never call this from non-test code.
func OverrideRootCAForTest(root *x509.Certificate) func() {
	verifyRootMu.Lock()
	prev := verifyRoot
	verifyRoot = root
	verifyRootMu.Unlock()
	return func() {
		verifyRootMu.Lock()
		verifyRoot = prev
		verifyRootMu.Unlock()
	}
}

// MDAResult contains the parsed device properties from an MDA certificate.
type MDAResult struct {
	Valid bool

	// Device identity (from OIDs or subject).
	DeviceSerial string
	DeviceUDID   string

	// Security properties from the device-attest OID set (100.8.13.*).
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
		return nil, errors.New("mda: empty certificate chain")
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
	roots.AddCert(currentVerifyRoot())

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
			result.DeviceSerial = attestationwire.ParseStringOID(ext.Value)
		case ext.Id.Equal(OIDDeviceUDID):
			result.DeviceUDID = attestationwire.ParseStringOID(ext.Value)

		// Device version OIDs (100.8.10.*)
		case ext.Id.Equal(OIDOSVersion):
			result.OSVersion = attestationwire.ParseStringOID(ext.Value)
		case ext.Id.Equal(OIDSepOSVersion):
			result.SepOSVersion = attestationwire.ParseStringOID(ext.Value)
		case ext.Id.Equal(OIDLLBVersion):
			result.LLBVersion = attestationwire.ParseStringOID(ext.Value)

		// Freshness (100.8.11.*)
		case ext.Id.Equal(OIDFreshnessCode):
			var raw asn1.RawValue
			if _, err := asn1.Unmarshal(ext.Value, &raw); err == nil {
				result.FreshnessCode = raw.Bytes
			} else {
				result.FreshnessCode = ext.Value
			}

		// Device-attest OIDs (100.8.13.*) — may also be present
		case ext.Id.Equal(OIDSIPStatus):
			result.SIPEnabled = attestationwire.ParseBoolOID(ext.Value)
		case ext.Id.Equal(OIDSecureBootStatus):
			result.SecureBootEnabled = attestationwire.ParseBoolOID(ext.Value)
		case ext.Id.Equal(OIDKextStatus):
			result.ThirdPartyKexts = attestationwire.ParseBoolOID(ext.Value)
		}
	}

	return result, nil
}
