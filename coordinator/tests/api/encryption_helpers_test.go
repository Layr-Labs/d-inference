package api_test

import (
	"crypto/rand"
	"encoding/base64"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"golang.org/x/crypto/nacl/box"
)

func testPrivacyCaps() *protocol.PrivacyCapabilities {
	return &protocol.PrivacyCapabilities{
		TextBackendInprocess: true,
		TextProxyDisabled:    true,
		SIPEnabled:           true,
		AntiDebugEnabled:     true,
		CoreDumpsDisabled:    true,
		EnvScrubbed:          true,
	}
}

// testPublicKeyB64 generates a real X25519 keypair for tests and returns the
// provider public key.
func testPublicKeyB64() string {
	pub, _, err := box.GenerateKey(rand.Reader)
	if err != nil {
		panic(err)
	}
	return base64.StdEncoding.EncodeToString(pub[:])
}
