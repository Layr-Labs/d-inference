// Package attestation — MDA (Managed Device Attestation) certificate chain
// verification.
//
// Apple's Managed Device Attestation allows MDM-enrolled devices to generate
// certificates containing device identity and security properties signed by
// Apple's Enterprise Attestation Root CA. This provides hardware-backed
// attestation that cannot be spoofed by a compromised OS.
//
// Two attestation paths exist:
//  1. ACME device-attest-01: OIDs in 1.2.840.113635.100.8.13.* (SIP, SecureBoot, Kext)
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
	"time"
)

// Apple MDA OID constants — ACME device-attest-01 path (existing).
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

	// SEP-measured security properties (100.8.13.*, macOS 14.2+). On real Apple
	// certs .13.1/.13.3 are DER INTEGERs and .13.2 is a RAW (unwrapped) string —
	// verified against live fleet certs. All three fail CLOSED: an absent or
	// unparseable value reads as the less-secure state.
	SIPEnabled        bool   // .13.1 INTEGER == 0 (Apple: "0 indicates enabled, 1 indicates disabled")
	SecureBootEnabled bool   // .13.2 == "Full Security" exactly ("Reduced"/"Permissive" are NOT full)
	ThirdPartyKexts   bool   // .13.3 INTEGER != 0 (Apple: any nonzero allows some kexts)
	BootState         string // raw .13.2 value: "Full Security" | "Reduced Security" | "Permissive Security"

	// Device properties from DevicePropertiesAttestation OIDs.
	OSVersion    string
	SepOSVersion string
	LLBVersion   string

	// Freshness code — the RAW bytes of the DeviceAttestationNonce we sent (Apple
	// embeds the nonce verbatim, NOT a hash of it; for the MDM DeviceInformation
	// flow the cert may carry a PREVIOUS nonce when the device returns its cached
	// attestation under Apple's ~7-day rate limit).
	FreshnessCode []byte

	// LeafNotBefore is the leaf certificate's NotBefore — the mint time of this
	// attestation. Drives the routing-time staleness bound (MDAMaxCertAge).
	LeafNotBefore time.Time

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
	parseAppleAttestationExtensions(leaf, result)

	return result, nil
}

// parseAppleAttestationExtensions extracts every Apple attestation OID we
// consume from the leaf certificate into result, plus the leaf mint time.
// Shared by the DER (MDM DeviceInformation) and PEM (ACME) verification paths.
func parseAppleAttestationExtensions(leaf *x509.Certificate, result *MDAResult) {
	result.LeafNotBefore = leaf.NotBefore

	// Serial from subject (standard X.509 field); the .9.1 OID overrides below.
	if leaf.Subject.SerialNumber != "" {
		result.DeviceSerial = leaf.Subject.SerialNumber
	}

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

		// Freshness (100.8.11.*) — the raw nonce bytes.
		case ext.Id.Equal(OIDFreshnessCode):
			result.FreshnessCode = unwrapFreshnessCode(ext.Value)

		// SEP-measured security OIDs (100.8.13.*, macOS 14.2+).
		//
		// Live Apple certs encode .13.1/.13.3 as DER INTEGERs (`02 01 00` = SIP
		// fully on / no kexts) and .13.2 as a RAW unwrapped string
		// ("Full Security"). The previous parseBoolOID treated all three as
		// ASN.1 booleans with a last-byte!=0 fallback, which INVERTED .13.1
		// (INTEGER 0 → false) and read every .13.2 boot level as true. All
		// three now fail CLOSED on absent/unparseable values.
		case ext.Id.Equal(OIDSIPStatus):
			v, ok := parseIntOID(ext.Value)
			result.SIPEnabled = ok && v == 0
		case ext.Id.Equal(OIDSecureBootStatus):
			result.BootState = parseStringOID(ext.Value)
			result.SecureBootEnabled = result.BootState == "Full Security"
		case ext.Id.Equal(OIDKextStatus):
			v, ok := parseIntOID(ext.Value)
			result.ThirdPartyKexts = !ok || v != 0
		}
	}
}

// VerifyMDACertChain verifies a PEM-encoded MDA certificate chain.
// Kept for backward compatibility with the ACME path.
func VerifyMDACertChain(certChainPEM []byte, appleRootCA *x509.Certificate) (*MDAResult, error) {
	certs, err := parsePEMCertificates(certChainPEM)
	if err != nil {
		return nil, fmt.Errorf("mda: failed to parse certificate chain: %w", err)
	}

	if len(certs) == 0 {
		return nil, errors.New("mda: empty certificate chain")
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
	parseAppleAttestationExtensions(leaf, result)

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

// unwrapFreshnessCode returns the nonce bytes from the FreshnessCode extension.
// Live Apple certs carry the nonce RAW (exactly the bytes we sent, no inner
// DER). Unwrap an inner OCTET STRING only when the value unambiguously is one
// (leading universal 0x04 tag and the TLV spans the whole value). The previous
// code blindly asn1.Unmarshal'd into a RawValue: a raw 32-byte nonce can start
// with any byte, and many of those "parse" as some shorter TLV — silently
// slicing the nonce to garbage and breaking the SE-key-binding comparison for
// a random fraction of devices.
func unwrapFreshnessCode(data []byte) []byte {
	// The nonce we send (and thus the expected FreshnessCode) is exactly
	// mdaNonceLen bytes. Live certs carry it raw at that length, so a value
	// already == mdaNonceLen is never a wrapper of itself — leaving it alone
	// avoids shortening a raw nonce that merely happens to begin with 0x04 (the
	// OCTET STRING tag). Only attempt to unwrap an off-length value, and only
	// when the inner content is the full nonce length.
	if len(data) != mdaNonceLen && len(data) > 0 && data[0] == 0x04 {
		var raw asn1.RawValue
		if rest, err := asn1.Unmarshal(data, &raw); err == nil && len(rest) == 0 && len(raw.Bytes) == mdaNonceLen {
			return raw.Bytes
		}
	}
	return data
}

// parseIntOID parses a DER INTEGER extension value (the format live Apple certs
// use for .13.1 and .13.3, e.g. `02 01 00`). It also accepts ASCII digits as a
// defensive fallback. Returns ok=false for anything else — callers must treat
// that as the less-secure state (fail closed). It deliberately does NOT fall
// back to last-byte inspection: that heuristic is what previously inverted the
// SIP bit (DER INTEGER 0 ends in 0x00 → read as "disabled").
func parseIntOID(data []byte) (int64, bool) {
	var val int64
	if _, err := asn1.Unmarshal(data, &val); err == nil {
		return val, true
	}
	if len(data) > 0 && len(data) <= 19 {
		n := int64(0)
		for _, b := range data {
			if b < '0' || b > '9' {
				return 0, false
			}
			n = n*10 + int64(b-'0')
		}
		return n, true
	}
	return 0, false
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
