package transcript

import "encoding/base64"

// Endpoint uses only the registry's accepted key, not the registration claim.
func Endpoint(key string) (string, bool) {
	if len(key) != 44 {
		return "", false
	}
	decoded, err := base64.StdEncoding.DecodeString(key)
	if err != nil || len(decoded) != 32 || base64.StdEncoding.EncodeToString(decoded) != key {
		return "", false
	}
	return key, true
}
