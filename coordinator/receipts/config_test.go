package receipts

import (
	"crypto/ed25519"
	"encoding/base64"
	"reflect"
	"strings"
	"testing"
)

func testReceiptConfig(t *testing.T) (Config, ed25519.PublicKey) {
	t.Helper()
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = byte(i + 1)
	}
	return Config{
		Enabled:      true,
		SigningKeyID: "receipt-2026-09",
		SigningKey:   base64.StdEncoding.EncodeToString(seed),
	}, ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)
}

func TestConfigCheckAcceptsDisabledAndValidSigner(t *testing.T) {
	if err := (Config{SigningKey: "not base64"}).Check(); err != nil {
		t.Fatalf("disabled config with ignored key fields: %v", err)
	}
	cfg, _ := testReceiptConfig(t)
	if err := cfg.Check(); err != nil {
		t.Fatalf("valid enabled config: %v", err)
	}
}

func TestConfigCheckFailsBootOnUnusableKeys(t *testing.T) {
	_, otherPublic, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	valid, _ := testReceiptConfig(t)
	for name, mutate := range map[string]func(*Config){
		"missing key ID":      func(c *Config) { c.SigningKeyID = "" },
		"missing signing key": func(c *Config) { c.SigningKey = "" },
		"non-base64 key":      func(c *Config) { c.SigningKey = "%%%" },
		"short key":           func(c *Config) { c.SigningKey = base64.StdEncoding.EncodeToString([]byte("short")) },
		"public keys not JSON": func(c *Config) {
			c.PublicKeysJSON = "old=abc"
		},
		"public key wrong size": func(c *Config) {
			c.PublicKeysJSON = `{"old":"` + base64.StdEncoding.EncodeToString([]byte("short")) + `"}`
		},
		"active ID with different key": func(c *Config) {
			c.PublicKeysJSON = `{"receipt-2026-09":"` + base64.StdEncoding.EncodeToString(otherPublic) + `"}`
		},
	} {
		t.Run(name, func(t *testing.T) {
			cfg := valid
			mutate(&cfg)
			err := cfg.Check()
			if err == nil {
				t.Fatal("Check accepted unusable receipt keys")
			}
			if strings.Contains(err.Error(), valid.SigningKey) {
				t.Fatalf("Check error echoes the signing secret: %v", err)
			}
		})
	}
}

func TestReadConfigRejectsMalformedEnabledSwitch(t *testing.T) {
	t.Setenv(envEnabled, "ture")
	cfg := ReadConfig()
	if cfg.Enabled {
		t.Fatal("malformed ENABLED value enabled receipts")
	}
	if err := cfg.Check(); err == nil || !strings.Contains(err.Error(), envEnabled) {
		t.Fatalf("Check error = %v, want it to name %s", err, envEnabled)
	}
}

func TestReadConfigReadsEnvironment(t *testing.T) {
	want, _ := testReceiptConfig(t)
	t.Setenv(envEnabled, "true")
	t.Setenv(envSigningKeyID, " "+want.SigningKeyID+" ")
	t.Setenv(envSigningKey, want.SigningKey)
	t.Setenv(envPublicKeys, "")
	if got := ReadConfig(); !reflect.DeepEqual(got, want) {
		t.Fatalf("ReadConfig = %+v, want %+v", got, want)
	}
}

func TestKeyRingPublishesActiveAndRetainedKeys(t *testing.T) {
	cfg, active := testReceiptConfig(t)
	retired, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	cfg.PublicKeysJSON = `{"receipt-2026-06":"` + base64.StdEncoding.EncodeToString(retired) + `"}`
	ring, err := cfg.KeyRing()
	if err != nil {
		t.Fatal(err)
	}
	if got := ring.KeyIDs(); !reflect.DeepEqual(got, []string{"receipt-2026-06", "receipt-2026-09"}) {
		t.Fatalf("KeyIDs = %v", got)
	}
	if key, ok := ring.PublicKey("receipt-2026-09"); !ok || !key.Equal(active) {
		t.Fatal("active public key is not published")
	}
	if key, ok := ring.PublicKey("receipt-2026-06"); !ok || !key.Equal(retired) {
		t.Fatal("retained public key is not published")
	}
	if ring.Signer().KeyID() != "receipt-2026-09" {
		t.Fatalf("signer key ID = %q", ring.Signer().KeyID())
	}
	if disabled, err := (Config{}).KeyRing(); disabled != nil || err != nil {
		t.Fatalf("disabled KeyRing = (%v, %v), want (nil, nil)", disabled, err)
	}
}
