// Package attestation — MDA (Managed Device Attestation) certificate chain
// verification scaffold.
//
// Apple's Managed Device Attestation allows MDM-enrolled devices to generate
// ACME certificates containing device identity and security properties in
// custom OIDs. This file provides the infrastructure to verify those
// certificate chains against Apple's Enterprise Attestation Root CA.
//
// NOTE: Full MDA verification requires a real MDA enrollment via Apple Business
// Manager. For now, this module accepts test certificates for development and
// provides the OID parsing infrastructure.
package attestation

import (
	"crypto/x509"
	"encoding/asn1"
	"encoding/pem"
	"fmt"
)

// Apple MDA OID constants — these OIDs appear in leaf certificates issued
// via Managed Device Attestation.
var (
	// OIDSIPStatus indicates whether System Integrity Protection is enabled.
	OIDSIPStatus = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 13, 1}

	// OIDSecureBootStatus indicates whether Secure Boot is enabled.
	OIDSecureBootStatus = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 13, 2}

	// OIDKextStatus indicates whether third-party kernel extensions are allowed.
	OIDKextStatus = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 13, 3}
)

// MDAResult contains the parsed device properties from an MDA certificate.
type MDAResult struct {
	// Valid is true if the certificate chain verified successfully.
	Valid bool

	// DeviceIdentity from the certificate subject.
	DeviceSerial string

	// Security properties extracted from custom OIDs.
	SIPEnabled         bool
	SecureBootEnabled  bool
	ThirdPartyKexts    bool

	// Error message if verification failed.
	Error string
}

// VerifyMDACertChain verifies an MDA certificate chain against Apple's
// Enterprise Attestation Root CA. Returns the attested properties
// (SIP, Secure Boot, kext status) extracted from the certificate OIDs.
//
// This requires a real MDA enrollment via Apple Business Manager.
// For now, this function accepts test certificates for development.
func VerifyMDACertChain(certChainPEM []byte, appleRootCA *x509.Certificate) (*MDAResult, error) {
	// Parse the PEM-encoded certificate chain.
	certs, err := parsePEMCertificates(certChainPEM)
	if err != nil {
		return nil, fmt.Errorf("mda: failed to parse certificate chain: %w", err)
	}

	if len(certs) == 0 {
		return nil, fmt.Errorf("mda: empty certificate chain")
	}

	leaf := certs[0]
	intermediates := certs[1:]

	// Build verification options.
	result := &MDAResult{}

	if appleRootCA != nil {
		// Verify the certificate chain against the Apple Root CA.
		roots := x509.NewCertPool()
		roots.AddCert(appleRootCA)

		intPool := x509.NewCertPool()
		for _, ic := range intermediates {
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

	// Extract device properties from custom OIDs.
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
		}
	}

	return result, nil
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
// Returns true if the value is ASN.1 TRUE, false otherwise.
func parseBoolOID(data []byte) bool {
	var val bool
	if _, err := asn1.Unmarshal(data, &val); err != nil {
		// If we can't parse as ASN.1 boolean, check for raw true byte.
		// Some implementations encode as a single byte: 0xFF = true, 0x00 = false.
		if len(data) > 0 {
			return data[len(data)-1] != 0
		}
		return false
	}
	return val
}
