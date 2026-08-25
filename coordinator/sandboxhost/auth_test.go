package sandboxhost

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"
)

const testHostID = "aaaaaaaa-0000-0000-0000-000000000001"

func TestAuthenticatorUsesPerHostSHA256Credentials(t *testing.T) {
	token := strings.Repeat("a", 32)
	hash := sha256.Sum256([]byte(token))
	authenticator, err := NewAuthenticator(AuthConfig{
		TokenSHA256JSON: `{"` + testHostID + `":"` +
			hex.EncodeToString(hash[:]) + `"}`,
	})
	if err != nil {
		t.Fatalf("new authenticator: %v", err)
	}
	if !authenticator.Enabled() {
		t.Fatal("configured authenticator is disabled")
	}
	if !authenticator.Authenticate(testHostID, token) {
		t.Fatal("valid sandbox host credential was rejected")
	}
	if !authenticator.Authenticate(strings.ToUpper(testHostID), token) {
		t.Fatal("canonical uppercase UUID was rejected")
	}
	if authenticator.Authenticate(testHostID, strings.Repeat("b", 32)) {
		t.Fatal("incorrect sandbox host token was accepted")
	}
	if authenticator.Authenticate(
		"00000000-0000-0000-0000-000000000002",
		token,
	) {
		t.Fatal("token was accepted for another sandbox host")
	}
}

func TestAuthenticatorRejectsAmbiguousConfiguration(t *testing.T) {
	hash := strings.Repeat("0", sha256.Size*2)
	for name, raw := range map[string]string{
		"invalid hash": `{"` + testHostID + `":"00"}`,
		"invalid host": `{"not-a-uuid":"` + hash + `"}`,
		"duplicate host": `{"` + testHostID + `":"` + hash + `","` +
			strings.ToUpper(testHostID) + `":"` + hash + `"}`,
		"trailing JSON": `{"` + testHostID + `":"` + hash + `"} {}`,
		"empty map":     `{}`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := NewAuthenticator(AuthConfig{
				TokenSHA256JSON: raw,
			}); err == nil {
				t.Fatal("invalid sandbox host auth config was accepted")
			}
		})
	}
}

func TestEmptyAuthenticatorFailsClosed(t *testing.T) {
	authenticator, err := NewAuthenticator(AuthConfig{})
	if err != nil {
		t.Fatalf("empty authenticator: %v", err)
	}
	if authenticator.Enabled() {
		t.Fatal("empty authenticator is enabled")
	}
	if authenticator.Authenticate(testHostID, strings.Repeat("a", 32)) {
		t.Fatal("disabled authenticator accepted a token")
	}
}
