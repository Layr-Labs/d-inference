package globalpayouts_test

import (
	"encoding/json"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/billing/globalpayouts"
)

func TestFundingIncludesFractionalFeesAndRejectsInvalidEstimates(t *testing.T) {
	n, err := production.RequiredFundingCents(1000, json.RawMessage(`[{"amount":{"currency":"usd","value":150.25}}]`))
	if err != nil || n != 1151 {
		t.Fatalf("funding %d %v", n, err)
	}
	for _, raw := range []string{`[{"amount":{"currency":"eur","value":1}}]`, `[{"amount":{"currency":"usd","value":-1}}]`, `[{"amount":{"currency":"usd","value":9999999999999999999999999999}}]`} {
		if _, err := production.RequiredFundingCents(1000, []byte(raw)); err == nil {
			t.Fatalf("accepted invalid fee: %s", raw)
		}
	}
}
