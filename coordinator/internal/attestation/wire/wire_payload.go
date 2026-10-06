package wire

import (
	"encoding/json"
	"math/big"
)

// AttestationBlob mirrors the Swift AttestationBlob struct.
// JSON field names must match exactly for signature verification.
// AttestationBlob fields are in alphabetical order by JSON key name.
// This is critical: Go's json.Marshal uses struct declaration order,
// and Swift's JSONEncoder with .sortedKeys uses alphabetical order.
// Keeping them aligned ensures both produce identical JSON.
type AttestationBlob struct {
	AuthenticatedRootEnabled bool     `json:"authenticatedRootEnabled"`
	BinaryHash               string   `json:"binaryHash,omitempty"`
	ChipFamily               string   `json:"chipFamily,omitempty"`
	ChipName                 string   `json:"chipName"`
	EncryptionPublicKey      string   `json:"encryptionPublicKey,omitempty"`
	HardwareModel            string   `json:"hardwareModel"`
	MetallibHash             string   `json:"metallibHash,omitempty"`
	OSVersion                string   `json:"osVersion"`
	PublicKey                string   `json:"publicKey"`
	RDMADisabled             bool     `json:"rdmaDisabled"`
	RuntimeCapabilities      []string `json:"runtimeCapabilities,omitempty"`
	SecureBootEnabled        bool     `json:"secureBootEnabled"`
	SecureEnclaveAvailable   bool     `json:"secureEnclaveAvailable"`
	SerialNumber             string   `json:"serialNumber,omitempty"`
	SIPEnabled               bool     `json:"sipEnabled"`
	SystemVolumeHash         string   `json:"systemVolumeHash,omitempty"`
	Timestamp                string   `json:"timestamp"`
}

// ecdsaSig holds the two integers in a DER-encoded ECDSA signature.
type ECDSASignature struct {
	R, S *big.Int
}

// marshalSortedJSON re-encodes the attestation blob as JSON with keys
// in alphabetical order, matching Swift's JSONEncoder with .sortedKeys.
//
// Go's encoding/json marshals struct fields in declaration order, which
// may not match Swift's alphabetical order. We use a map to ensure
// correct key ordering.
func MarshalSortedJSON(blob AttestationBlob) ([]byte, error) {
	// Build an ordered map matching Swift's .sortedKeys output.
	// Swift sorts keys alphabetically (Unicode code point order).
	// encoding/json marshals map keys in sorted order as of Go 1.12+.
	m := map[string]interface{}{
		"authenticatedRootEnabled": blob.AuthenticatedRootEnabled,
		"chipName":                 blob.ChipName,
		"hardwareModel":            blob.HardwareModel,
		"osVersion":                blob.OSVersion,
		"publicKey":                blob.PublicKey,
		"rdmaDisabled":             blob.RDMADisabled,
		"secureBootEnabled":        blob.SecureBootEnabled,
		"secureEnclaveAvailable":   blob.SecureEnclaveAvailable,
		"sipEnabled":               blob.SIPEnabled,
		"timestamp":                blob.Timestamp,
	}

	// Only include optional fields if set (Swift's JSONEncoder with
	// .sortedKeys omits nil optionals, so we must match that behavior).
	if blob.ChipFamily != "" {
		m["chipFamily"] = blob.ChipFamily
	}
	if blob.BinaryHash != "" {
		m["binaryHash"] = blob.BinaryHash
	}
	if blob.EncryptionPublicKey != "" {
		m["encryptionPublicKey"] = blob.EncryptionPublicKey
	}
	if blob.MetallibHash != "" {
		m["metallibHash"] = blob.MetallibHash
	}
	if blob.SerialNumber != "" {
		m["serialNumber"] = blob.SerialNumber
	}
	if len(blob.RuntimeCapabilities) > 0 {
		m["runtimeCapabilities"] = blob.RuntimeCapabilities
	}
	if blob.SystemVolumeHash != "" {
		m["systemVolumeHash"] = blob.SystemVolumeHash
	}

	return json.Marshal(m)
}
