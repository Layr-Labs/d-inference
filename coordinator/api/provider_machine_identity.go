package api

import (
	"crypto/sha256"
	"encoding/hex"
)

const providerMachineIdentityNamespace = "darkbloom-provider-machine-v1\x00"

// providerMachineID gives the app a stable grouping key without returning the
// hardware serial in the earnings payload. ProviderCoreFoundation implements
// the same namespaced digest so the local CLI can identify the current Mac.
func providerMachineID(serialNumber string) string {
	if serialNumber == "" {
		return ""
	}
	digest := sha256.Sum256([]byte(providerMachineIdentityNamespace + serialNumber))
	return hex.EncodeToString(digest[:])
}
