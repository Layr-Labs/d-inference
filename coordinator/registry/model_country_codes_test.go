package registry

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// ModelCountryCodes must only count routing-eligible providers (same gates as
// ListModels), so a country whose providers can't actually serve the model is
// not advertised in the OpenRouter datacenters field.
func TestModelCountryCodesOnlyEligibleProviders(t *testing.T) {
	reg := New(testLogger())
	const model = "mlx-community/Qwen3.5-9B-Instruct-4bit"

	// Eligible provider in the US (trusted + private-ready).
	good := reg.Register("good", nil, testRegisterMessage())
	testMakeTextRoutable(good)
	good.mu.Lock()
	good.Location = &store.ProviderLocation{CountryCode: "us"}
	good.mu.Unlock()

	// Online but NOT routing-eligible (never made text-routable → no verified
	// SIP, so not private-ready) provider in DE, serving the same model.
	bad := reg.Register("bad", nil, testRegisterMessage())
	bad.mu.Lock()
	bad.Location = &store.ProviderLocation{CountryCode: "DE"}
	bad.mu.Unlock()

	got := reg.ModelCountryCodes(model)
	if len(got) != 1 || got[0] != "US" {
		t.Fatalf("country codes = %v, want [US] (the DE provider is not routing-eligible)", got)
	}
}

func TestModelCountryCodesExcludesPrivateOnlyProviders(t *testing.T) {
	reg := New(testLogger())
	const model = "mlx-community/Qwen3.5-9B-Instruct-4bit"
	for _, row := range []struct {
		id, country string
		private     bool
	}{
		{"public", "us", false},
		{"private", "IN", true},
	} {
		p := reg.Register(row.id, nil, testRegisterMessage())
		testMakeTextRoutable(p)
		p.mu.Lock()
		p.PrivateOnly = row.private
		p.Location = &store.ProviderLocation{CountryCode: row.country}
		p.mu.Unlock()
	}
	if codes := reg.ModelCountryCodes(model); len(codes) != 1 || codes[0] != "US" {
		t.Fatalf("public datacenters include a private self-route provider: %v", codes)
	}
	// When every eligible provider becomes private, no country is advertised.
	p := reg.GetProvider("public")
	p.mu.Lock()
	p.PrivateOnly = true
	p.mu.Unlock()
	if codes := reg.ModelCountryCodes(model); len(codes) != 0 {
		t.Fatalf("private-only model has public datacenters: %v", codes)
	}
}
