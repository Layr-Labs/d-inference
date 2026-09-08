package attestation

import "encoding/asn1"

// Apple encodes SIP as an INTEGER (zero means enabled) and Secure Boot as a
// string. A signature authenticates these bytes; it does not repair an unknown
// encoding or turn an absent measurement into a passing posture.
func parseSIPMeasurement(data []byte) (enabled, known bool) {
	var status int
	rest, err := asn1.Unmarshal(data, &status)
	if err != nil || len(rest) != 0 || status < 0 {
		return false, false
	}
	return status == 0, true
}

func parseSecureBootMeasurement(data []byte) (full, known bool) {
	var status string
	rest, err := asn1.Unmarshal(data, &status)
	if err != nil || len(rest) != 0 {
		return false, false
	}
	switch status {
	case "Full Security":
		return true, true
	case "Reduced Security", "Permissive Security":
		return false, true
	default:
		return false, false
	}
}
