package protocol_test

import (
	"encoding/json"
	"strings"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestAppAttestAppleErrorBoundsAndOptionalEncoding(t *testing.T) {
	code := int64(-34018)
	valid := &production.AppAttestAppleError{Domain: "devicecheck", Code: 2, UnderlyingDomain: "osstatus", UnderlyingCode: &code}
	if !valid.Valid() || !(*production.AppAttestAppleError)(nil).Valid() {
		t.Fatal("bounded native error or legacy omission rejected")
	}
	for _, invalid := range []production.AppAttestAppleError{
		{Domain: "raw.private.domain", Code: 2},
		{Domain: "devicecheck", Code: 1 << 40},
		{Domain: "devicecheck", Code: 2, UnderlyingDomain: "url"},
		{Domain: "devicecheck", Code: 2, UnderlyingCode: &code},
	} {
		if invalid.Valid() {
			t.Fatalf("unbounded diagnostics accepted: %+v", invalid)
		}
	}
	body, err := json.Marshal(production.AppAttestShadowPayload{Action: "ready", Session: "session"})
	if err != nil || strings.Contains(string(body), "apple_error") {
		t.Fatalf("absent diagnostics changed legacy encoding: %s, %v", body, err)
	}
	body, err = json.Marshal(valid)
	if err != nil || !strings.Contains(string(body), `"underlying_code":-34018`) {
		t.Fatalf("native cause lost: %s, %v", body, err)
	}
}
