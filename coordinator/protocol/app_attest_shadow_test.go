package protocol

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
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

func TestAppAttestOversizedFrameErrorIsSpecific(t *testing.T) {
	padding := bytes.Repeat([]byte(" "), 48*1024)
	for _, discriminator := range []string{`"app_attest_shadow"`, `"app_attest_\u0073hadow"`} {
		frame := append([]byte(`{"type":`+discriminator+`,"payload":{"action":"assertion"}}`), padding...)
		var decoded ProviderMessage
		if err := DecodeProviderMessage(frame, &decoded); !errors.Is(err, ErrAppAttestShadowFrameTooLarge) {
			t.Fatalf("oversized shadow frame not identifiable: %v", err)
		}
		if decoded.Payload != nil {
			t.Fatal("oversized shadow payload was decoded")
		}
	}
	var decoded ProviderMessage
	if err := DecodeProviderMessage(append([]byte(`{"type":"heartbeat"}`), padding...), &decoded); err != nil {
		t.Fatalf("shadow limit incorrectly applied to a different frame type: %v", err)
	}
	if err := DecodeProviderMessage([]byte(`{"type":"app_attest_shadow","payload":42}`), &decoded); err == nil || errors.Is(err, ErrAppAttestShadowFrameTooLarge) {
		t.Fatalf("ordinary decode error misclassified as oversized: %v", err)
	}
}

func TestAppAttestV2TranscriptBindsAccountAndStatus(t *testing.T) {
	b64 := func(b byte) string { return base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{b}, 32)) }
	scope := string(bytes.Repeat([]byte("a"), 64))
	status := &AppAttestStatus{OSVersion: "27.0.0", OSBuild: "26A428", AppVersion: "0.9.2", Chip: "Apple M5 Max", BinaryHash: string(bytes.Repeat([]byte("b"), 64))}
	hash := AppAttestShadowHashV2("assert", b64(0), "production", b64(1), b64(2), b64(3), scope, status)
	if hex.EncodeToString(hash[:]) != "91a11ff692299f9b8237fa9aaabde46de9f4dbbe5b9b00108b979cd985e1aae6" {
		t.Fatal("Swift v2 drift")
	}
	status.OSBuild = "spoofed"
	if hash == AppAttestShadowHashV2("assert", b64(0), "production", b64(1), b64(2), b64(3), scope, status) {
		t.Fatal("status not bound")
	}
}
