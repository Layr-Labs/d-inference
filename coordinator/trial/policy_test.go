package trial

import "testing"

func configuredTrial() Config {
	c := DefaultConfig()
	c.Enabled = true
	c.ModelIDs = []string{BonsaiBuildID, "synthetic-approved-fallback"}
	c.Rates = Rates{10_000, 30_000}
	return c
}

func TestDefaultConfigGrantsNothing(t *testing.T) {
	c := DefaultConfig()
	if c.Enabled || len(c.ModelIDs) != 0 || c.TokenLimit != 5_000_000 || c.CampaignID == "" {
		t.Fatalf("unsafe defaults: %+v", c)
	}
	if err := c.Validate(); err != nil {
		t.Fatal(err)
	}
	if c.Matches(AuthSession, ChatEndpoint, BonsaiBuildID) {
		t.Fatal("unconfigured default grants a model")
	}
	c.Enabled = true
	if c.Validate() == nil {
		t.Fatal("enabling without explicit identity and prices must fail")
	}
}

func TestConfigValidation(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*Config)
	}{
		{"missing campaign", func(c *Config) { c.CampaignID = "" }},
		{"padded campaign", func(c *Config) { c.CampaignID = " campaign " }},
		{"zero limit", func(c *Config) { c.TokenLimit = 0 }},
		{"negative limit", func(c *Config) { c.TokenLimit = -1 }},
		{"missing models", func(c *Config) { c.ModelIDs = nil }},
		{"blank model", func(c *Config) { c.ModelIDs = []string{""} }},
		{"padded model", func(c *Config) { c.ModelIDs = []string{" " + BonsaiBuildID} }},
		{"duplicate model", func(c *Config) { c.ModelIDs = []string{BonsaiBuildID, BonsaiBuildID} }},
		{"zero input rate", func(c *Config) { c.Rates.InputMicroUSDPerMillion = 0 }},
		{"negative output rate", func(c *Config) { c.Rates.OutputMicroUSDPerMillion = -1 }},
	}
	if err := configuredTrial().Validate(); err != nil {
		t.Fatal(err)
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := configuredTrial()
			tc.mutate(&c)
			if c.Validate() == nil {
				t.Fatal("invalid enabled config accepted")
			}
		})
	}
}

func TestEligibilityRequiresVerifiedSessionExactEndpointAndModel(t *testing.T) {
	c := configuredTrial()
	for _, auth := range []AuthKind{"", AuthSession, AuthAPIKey, AuthAdmin, AuthProvider, "forged-session"} {
		for _, endpoint := range []string{ChatEndpoint, "/v1/responses", "/v1/completions", "/v1/messages", "/v1/chat/completions/", ""} {
			for _, model := range []string{BonsaiBuildID, "synthetic-approved-fallback", "Bonsai 2", BonsaiBuildID + "-other", ""} {
				want := auth == AuthSession && endpoint == ChatEndpoint && (model == BonsaiBuildID || model == "synthetic-approved-fallback")
				if got := c.Matches(auth, endpoint, model); got != want {
					t.Errorf("Matches(%q, %q, %q) = %v, want %v", auth, endpoint, model, got, want)
				}
			}
		}
	}
}

func TestDisableRetainsScopeAndCampaignIdentity(t *testing.T) {
	c := configuredTrial()
	id := c.CampaignID
	c.Enabled = false
	if !c.Matches(AuthSession, ChatEndpoint, BonsaiBuildID) {
		t.Fatal("disabled session scope must remain identifiable to reject rather than bill")
	}
	c.Enabled = true
	if c.CampaignID != id {
		t.Fatal("re-enabling changed persistent campaign identity")
	}
}
