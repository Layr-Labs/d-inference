package registry

import (
	"math"
	"testing"
)

func TestAccountAffinityConfiguration(t *testing.T) {
	t.Setenv(accountAffinityModeEnv, "")
	t.Setenv(accountAffinityMaxTTFTPenaltyEnv, "")
	defaults := ReadAccountAffinityConfig()
	if defaults.Mode != AccountAffinityOff || defaults.MaxTTFTPenaltyMs != 250 || defaults.Check() != nil {
		t.Fatalf("unexpected defaults: %+v", defaults)
	}
	for _, mode := range []string{AccountAffinityOff, AccountAffinityShadow, AccountAffinityOn} {
		t.Run(mode, func(t *testing.T) {
			t.Setenv(accountAffinityModeEnv, " "+mode+" ")
			t.Setenv(accountAffinityMaxTTFTPenaltyEnv, "0")
			cfg := ReadAccountAffinityConfig()
			if cfg.Mode != mode || cfg.MaxTTFTPenaltyMs != 0 || cfg.Check() != nil {
				t.Fatalf("explicit zero/mode not retained: %+v", cfg)
			}
		})
	}
	for _, raw := range []string{"-1", "NaN", "+Inf", "-Inf", "not-a-number"} {
		t.Run(raw, func(t *testing.T) {
			t.Setenv(accountAffinityMaxTTFTPenaltyEnv, raw)
			if ReadAccountAffinityConfig().Check() == nil {
				t.Fatal("invalid penalty accepted")
			}
		})
	}
	t.Setenv(accountAffinityModeEnv, "typo")
	if ReadAccountAffinityConfig().Check() == nil {
		t.Fatal("invalid mode accepted")
	}
	aggregate := ReadConfig()
	aggregate.AccountAffinity = AccountAffinityConfig{Mode: "typo"}
	if aggregate.Check() == nil {
		t.Fatal("aggregate registry configuration skipped affinity validation")
	}
}

func TestAccountAffinityConfigureIsAtomicAndNormalizes(t *testing.T) {
	r := New(testLogger())
	cfg := AccountAffinityConfig{Mode: " ON ", MaxTTFTPenaltyMs: 0}
	if err := r.ConfigureAccountAffinity(cfg); err != nil {
		t.Fatal(err)
	}
	if r.accountAffinity != (AccountAffinityConfig{Mode: AccountAffinityOn, MaxTTFTPenaltyMs: 0}) {
		t.Fatalf("unexpected installed config: %+v", r.accountAffinity)
	}
	previous := r.accountAffinity
	for _, invalid := range []AccountAffinityConfig{
		{Mode: "invalid"},
		{Mode: AccountAffinityOn, MaxTTFTPenaltyMs: -1},
		{Mode: AccountAffinityOn, MaxTTFTPenaltyMs: math.Inf(1)},
	} {
		if err := r.ConfigureAccountAffinity(invalid); err == nil {
			t.Fatalf("invalid configuration accepted: %+v", invalid)
		}
		if r.accountAffinity != previous {
			t.Fatal("invalid configuration partially applied")
		}
	}
	if err := r.ConfigureAccountAffinity(AccountAffinityConfig{}); err != nil || r.accountAffinity.Mode != AccountAffinityOff {
		t.Fatal("zero value did not disable affinity")
	}
}
