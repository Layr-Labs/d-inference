package trust

import (
	"strings"
	"testing"
)

func TestGenerateCombinedProfile(t *testing.T) {
	baseURL := "https://api.darkbloom.dev"

	profile := generateCombinedProfile(baseURL)

	// Must contain all 3 domain-specific URLs with the correct base
	expectedURLs := []string{
		"https://api.darkbloom.dev/scep",
		"https://api.darkbloom.dev/mdm/checkin",
		"https://api.darkbloom.dev/mdm/connect",
	}
	for _, url := range expectedURLs {
		if !strings.Contains(profile, url) {
			t.Errorf("profile missing URL: %s", url)
		}
	}

	// Must NOT contain the old hardcoded domain
	if strings.Contains(profile, "inference-test.openinnovation.dev") {
		t.Error("profile still contains old hardcoded domain")
	}

	// Profile identity is stable without containing hardware identity.
	if !strings.Contains(profile, "<string>io.darkbloom.enroll</string>") {
		t.Error("profile missing generic enrollment identifier")
	}
	if strings.Contains(profile, "PRIVATE-SERIAL") || strings.Contains(profile, "serial_number") {
		t.Error("profile contains device identity")
	}

	// Must contain the push topic
	if !strings.Contains(profile, "com.apple.mgmt.External.10520cbe-9635-453d-ac4e-c79aab56f8ce") {
		t.Error("profile missing MDM push topic")
	}

	// Must be valid XML plist
	if !strings.HasPrefix(profile, `<?xml version="1.0"`) {
		t.Error("profile is not valid XML plist")
	}

	// Must contain both payload types
	for _, payloadType := range []string{
		"com.apple.security.scep",
		"com.apple.mdm",
	} {
		if !strings.Contains(profile, payloadType) {
			t.Errorf("profile missing payload type: %s", payloadType)
		}
	}

	// The dormant ACME device-attest-01 payload was removed — it must be gone
	// so re-enrolls drop it (profile identity is unchanged, install replaces).
	for _, gone := range []string{"com.apple.security.acme", "/acme/", "io.darkbloom.enroll.acme."} {
		if strings.Contains(profile, gone) {
			t.Errorf("profile still contains removed ACME artifact: %s", gone)
		}
	}

	// Display strings are rebranded to Darkbloom. The capitalized "EigenInference"
	// must be gone from all visible fields (PayloadOrganization, SCEP subject,
	// display names).
	if strings.Contains(profile, "EigenInference") {
		t.Error("profile still contains capitalized 'EigenInference' display string")
	}
	if !strings.Contains(profile, "<string>Darkbloom</string>") {
		t.Error("profile missing Darkbloom PayloadOrganization")
	}
}
func TestGenerateCombinedProfileDifferentDomains(t *testing.T) {
	tests := []struct {
		name    string
		baseURL string
	}{
		{"production", "https://api.darkbloom.dev"},
		{"staging", "https://staging.darkbloom.dev"},
		{"localhost", "http://localhost:8080"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			profile := generateCombinedProfile(tt.baseURL)

			if !strings.Contains(profile, tt.baseURL+"/scep") {
				t.Errorf("expected SCEP URL with base %s", tt.baseURL)
			}
			if !strings.Contains(profile, tt.baseURL+"/mdm/checkin") {
				t.Errorf("expected CheckInURL with base %s", tt.baseURL)
			}
			if !strings.Contains(profile, tt.baseURL+"/mdm/connect") {
				t.Errorf("expected ServerURL with base %s", tt.baseURL)
			}
		})
	}
}
