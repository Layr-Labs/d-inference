package billing

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// TestCheckMockModeTripwire exercises the DAR-59 fail-closed guard in
// Config.Check via ReadConfig so that the real env-var→Config path is covered
// (not a hand-built Config struct that could drift from ReadConfig).
//
// Table layout:
//
//	(a) mock + no real creds  → loads fine
//	(b) mock + mnemonic set   → error
//	(c) mock + stripe key set → error
//	(d) no mock + real creds  → loads fine (production baseline)
func TestCheckMockModeTripwire(t *testing.T) {
	prefix := env.EnvPrefix // "EIGENINFERENCE"

	cases := []struct {
		name    string
		envs    map[string]string
		wantErr bool
		errFrag string // substring that must appear in the error message
	}{
		{
			name: "(a) mock only — no real creds — OK",
			envs: map[string]string{
				prefix + "_BILLING_MOCK": "true",
			},
			wantErr: false,
		},
		{
			name: "(b) mock + Solana mnemonic — must error",
			envs: map[string]string{
				prefix + "_BILLING_MOCK":    "true",
				prefix + "_SOLANA_MNEMONIC": "word1 word2 word3 word4 word5 word6 word7 word8 word9 word10 word11 word12",
			},
			wantErr: true,
			errFrag: "DAR-59",
		},
		{
			name: "(b2) mock + bare MNEMONIC env — must error",
			envs: map[string]string{
				prefix + "_BILLING_MOCK": "true",
				"MNEMONIC":               "word1 word2 word3 word4 word5 word6 word7 word8 word9 word10 word11 word12",
			},
			wantErr: true,
			errFrag: "DAR-59",
		},
		{
			name: "(c) mock + Stripe secret key — must error",
			envs: map[string]string{
				prefix + "_BILLING_MOCK":      "true",
				prefix + "_STRIPE_SECRET_KEY": "sk_live_fakekeyfortest",
			},
			wantErr: true,
			errFrag: "DAR-59",
		},
		{
			name: "(d) no mock + real creds — production baseline — OK",
			envs: map[string]string{
				prefix + "_SOLANA_MNEMONIC":   "word1 word2 word3 word4 word5 word6 word7 word8 word9 word10 word11 word12",
				prefix + "_STRIPE_SECRET_KEY": "sk_live_fakekeyfortest",
			},
			wantErr: false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			setBillingEnv(t, prefix, tc.envs)

			cfg := ReadConfig()
			err := cfg.Check()

			if tc.wantErr && err == nil {
				t.Fatalf("expected an error but Check() returned nil")
			}
			if !tc.wantErr && err != nil {
				t.Fatalf("expected no error but Check() returned: %v", err)
			}
			if tc.wantErr && tc.errFrag != "" && !strings.Contains(err.Error(), tc.errFrag) {
				t.Fatalf("error message %q does not contain expected fragment %q", err.Error(), tc.errFrag)
			}
		})
	}
}

// setBillingEnv isolates env state for one case: it clears every billing-related
// var (so cases can't leak into each other) and then applies the case's vars.
// t.Setenv restores all of them on test cleanup.
func setBillingEnv(t *testing.T, prefix string, envs map[string]string) {
	t.Helper()
	for _, key := range []string{
		prefix + "_BILLING_MOCK",
		prefix + "_SOLANA_MNEMONIC",
		prefix + "_MNEMONIC",
		"MNEMONIC",
		prefix + "_STRIPE_SECRET_KEY",
	} {
		t.Setenv(key, "")
	}
	for k, v := range envs {
		t.Setenv(k, v)
	}
}
