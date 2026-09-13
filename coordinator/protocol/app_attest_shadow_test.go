package protocol

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"testing"
)

func TestAppAttestShadowSwiftTranscriptAndWire(t *testing.T) {
	b64 := func(value byte) string { return base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{value}, 32)) }
	hash := AppAttestShadowHash("assert", b64(0), "production", b64(1), b64(2), b64(3))
	if hex.EncodeToString(hash[:]) != "6961d03f72d47b5e4d66746d590a82fabfca7a9fd4de48a05bfcef5c1e850449" {
		t.Fatal("Go/Swift transcript drift")
	}
	if hash == AppAttestShadowHash("assert", b64(0), "production", b64(1), b64(2), b64(4)) {
		t.Fatal("endpoint not bound")
	}
	wire, _ := json.Marshal(AppAttestShadowMessage{Type: TypeAppAttestShadow, Payload: AppAttestShadowPayload{Action: "ready", Session: b64(0), Result: "unsupported"}})
	var decoded ProviderMessage
	if err := DecodeProviderMessage(wire, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.Payload.(*AppAttestShadowMessage).Payload.Result != "unsupported" {
		t.Fatal("wire drift")
	}
	if err := DecodeProviderMessage(append(wire, bytes.Repeat([]byte(" "), 48*1024)...), &decoded); err == nil {
		t.Fatal("oversized frame accepted")
	}
}
