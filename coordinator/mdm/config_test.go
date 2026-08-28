package mdm

import "testing"

func TestConfigCheckRejectsMalformedURL(t *testing.T) {
	if err := (Config{URL: "micromdm", APIKey: "key"}).Check(); err == nil {
		t.Fatal("relative MDM URL was accepted")
	}
	if err := (Config{URL: "https://mdm.example.com", APIKey: "key"}).Check(); err != nil {
		t.Fatalf("valid MDM config rejected: %v", err)
	}
}
