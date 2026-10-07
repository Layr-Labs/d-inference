package wire

import (
	"encoding/asn1"
)

// parseBoolOID attempts to parse an ASN.1-encoded boolean from an extension value.
func ParseBoolOID(data []byte) bool {
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
func ParseStringOID(data []byte) string {
	var val string
	if _, err := asn1.Unmarshal(data, &val); err != nil {
		// Fallback: try raw bytes as string.
		return string(data)
	}
	return val
}
