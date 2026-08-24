package api

import (
	"fmt"
	"net/http"
	"regexp"

	"github.com/google/uuid"
)

// enrollRequest is the JSON body for POST /v1/enroll.
type enrollRequest struct {
	SerialNumber string `json:"serial_number"`
}

var serialRegex = regexp.MustCompile(`^[A-Z0-9]{8,14}$`)

// handleEnroll generates a per-device .mobileconfig containing MDM
// enrollment (SCEP + MDM payloads).
//
// No authentication required — the serial number is not secret. Trust comes
// from MDM SecurityInfo verification after enrollment, not from possession of
// the profile.
func (s *Server) handleEnroll(w http.ResponseWriter, r *http.Request) {
	var req enrollRequest
	if !decodeCappedJSON(w, r, maxControlPlaneBodyBytes, &req) {
		return
	}

	if req.SerialNumber == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "serial_number is required"))
		return
	}

	if !serialRegex.MatchString(req.SerialNumber) {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid serial number format"))
		return
	}

	s.logger.Info("generating enrollment + attestation profile",
		"serial_number", req.SerialNumber,
	)

	// Use the configured canonical base URL (EIGENINFERENCE_BASE_URL) for the
	// SCEP/MDM enrollment endpoints. Critically, since the profile is now
	// CMS-signed, deriving these from a client-controlled Host header would let an
	// attacker obtain a Darkbloom-signed .mobileconfig that points enrollment at
	// their own host — the signature would launder a malicious enrollment profile.
	// resolveBaseURL pins the configured URL and only falls back to the request
	// Host when no canonical URL is set (local/dev).
	baseURL := s.resolveBaseURL(r)

	body := []byte(generateCombinedProfile(req.SerialNumber, baseURL))

	// CMS-sign the profile so macOS can verify its provenance at install time.
	// Signing remains separate from the SCEP/MDM attestation chain inside. The
	// unsigned fallback is available only when startup explicitly configured it
	// for development/tests; required deployments fail closed here as a runtime
	// backstop if the signer is absent or fails.
	switch {
	case s.profileSigner == nil:
		if s.profileSigningRequired {
			s.logger.Error("required profile signer is unavailable", "serial_number", req.SerialNumber)
			s.ddIncr("enroll.profile_sign_required_missing", nil)
			writeJSON(w, http.StatusServiceUnavailable,
				errorResponse("server_error", "enrollment profile signing is unavailable"))
			return
		}
		s.ddIncr("enroll.profile_unsigned", nil)
	default:
		signed, err := s.profileSigner.Sign(body)
		if err != nil {
			s.ddIncr("enroll.profile_sign_error", nil)
			if s.profileSigningRequired {
				s.logger.Error("required profile signing failed",
					"serial_number", req.SerialNumber, "error", err)
				writeJSON(w, http.StatusServiceUnavailable,
					errorResponse("server_error", "enrollment profile signing is unavailable"))
				return
			}
			s.logger.Error("profile signing failed — serving unsigned profile",
				"serial_number", req.SerialNumber, "error", err)
		} else {
			body = signed
			s.ddIncr("enroll.profile_signed", nil)
		}
	}

	// A signed .mobileconfig keeps the same MIME type as an unsigned one.
	w.Header().Set("Content-Type", "application/x-apple-aspen-config")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="Darkbloom-Enroll-%s.mobileconfig"`, req.SerialNumber))
	w.WriteHeader(http.StatusOK)
	w.Write(body)
}

// generateCombinedProfile creates a .mobileconfig with two payloads:
//  1. SCEP — MDM identity certificate (for enrollment)
//  2. MDM — enrolls with MicroMDM (SecurityInfo verification)
//
// (A third ACME device-attest-01 payload existed historically, but the
// coordinator-side verification leg was never wired end-to-end and the leg was
// removed — hardware trust is earned via MDM SecurityInfo. Re-enrolling with
// this profile replaces the old one in place, dropping the dormant payload.)
//
// Display strings are branded "Darkbloom"; functional identifiers are deliberately
// NOT renamed so existing installs keep working and re-enrolls update in place: the
// io.darkbloom.enroll.* PayloadIdentifiers + SCEP/MDM PayloadUUIDs (macOS keys
// profile identity on these), and the MDM push Topic (tied to the APNs cert).
//
// AccessRights=1041: profile inspection (1) + device info queries (16) + security queries (1024).
// This is strictly read-only MDM — no device control or personal data access.
//
// Apple MDM AccessRights bitmask reference:
//
//	Bit 0  (1)    — Inspect installed config profiles          ✓ REQUESTED
//	Bit 1  (2)    — Install/remove config profiles             ✗ NOT requested
//	Bit 2  (4)    — Device lock and passcode removal           ✗ NOT requested
//	Bit 3  (8)    — Device erase (remote wipe)                 ✗ NOT requested
//	Bit 4  (16)   — Query device information (name, serial)    ✓ REQUESTED
//	Bit 5  (32)   — Query network information                  ✗ NOT requested
//	Bit 6  (64)   — Inspect installed provisioning profiles    ✗ NOT requested
//	Bit 7  (128)  — Install/remove provisioning profiles       ✗ NOT requested
//	Bit 8  (256)  — Inspect installed applications             ✗ NOT requested
//	Bit 9  (512)  — Restriction-related queries                ✗ NOT requested
//	Bit 10 (1024) — Security-related queries (SIP, SecureBoot) ✓ REQUESTED
//	Bit 11 (2048) — Change device settings                     ✗ NOT requested
//	Bit 12 (4096) — App management                             ✗ NOT requested
func generateCombinedProfile(serialNumber, baseURL string) string {
	profileUUID := uuid.New().String()

	return fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <!-- Payload 1: SCEP — MDM identity certificate -->
    <dict>
      <key>PayloadContent</key>
      <dict>
        <key>Challenge</key>
        <string>micromdm</string>
        <key>Key Type</key>
        <string>RSA</string>
        <key>Key Usage</key>
        <integer>5</integer>
        <key>Keysize</key>
        <integer>2048</integer>
        <key>Name</key>
        <string>Device Management Identity Certificate</string>
        <key>Subject</key>
        <array>
          <array>
            <array>
              <string>O</string>
              <string>Darkbloom</string>
            </array>
          </array>
          <array>
            <array>
              <string>CN</string>
              <string>Darkbloom Identity</string>
            </array>
          </array>
        </array>
        <key>URL</key>
        <string>%s/scep</string>
      </dict>
      <key>PayloadDescription</key>
      <string>Configures SCEP for MDM enrollment</string>
      <key>PayloadDisplayName</key>
      <string>SCEP</string>
      <key>PayloadIdentifier</key>
      <string>io.darkbloom.enroll.scep</string>
      <key>PayloadOrganization</key>
      <string>Darkbloom</string>
      <key>PayloadType</key>
      <string>com.apple.security.scep</string>
      <key>PayloadUUID</key>
      <string>D01D95F9-762E-4538-A9B3-4D949D55577C</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
    </dict>
    <!-- Payload 2: MDM — enrollment with MicroMDM -->
    <dict>
      <key>AccessRights</key>
      <integer>1041</integer>
      <key>CheckInURL</key>
      <string>%s/mdm/checkin</string>
      <key>CheckOutWhenRemoved</key>
      <true/>
      <key>IdentityCertificateUUID</key>
      <string>D01D95F9-762E-4538-A9B3-4D949D55577C</string>
      <key>PayloadDescription</key>
      <string>Enrolls with the Darkbloom coordinator for security verification</string>
      <key>PayloadIdentifier</key>
      <string>io.darkbloom.enroll.mdm</string>
      <key>PayloadOrganization</key>
      <string>Darkbloom</string>
      <key>PayloadType</key>
      <string>com.apple.mdm</string>
      <key>PayloadUUID</key>
      <string>4DF05DBF-6D20-41A4-8072-A51D327258E7</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
      <key>ServerCapabilities</key>
      <array>
        <string>com.apple.mdm.per-user-connections</string>
        <string>com.apple.mdm.bootstraptoken</string>
      </array>
      <key>ServerURL</key>
      <string>%s/mdm/connect</string>
      <key>SignMessage</key>
      <true/>
      <key>Topic</key>
      <string>com.apple.mgmt.External.10520cbe-9635-453d-ac4e-c79aab56f8ce</string>
    </dict>
  </array>
  <key>PayloadDescription</key>
  <string>Darkbloom provider enrollment. Grants read-only security verification (SIP, SecureBoot) via MDM.</string>
  <key>PayloadDisplayName</key>
  <string>Darkbloom Provider Enrollment</string>
  <key>PayloadIdentifier</key>
  <string>io.darkbloom.enroll.%s</string>
  <key>PayloadOrganization</key>
  <string>Darkbloom</string>
  <key>PayloadType</key>
  <string>Configuration</string>
  <key>PayloadUUID</key>
  <string>%s</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
</dict>
</plist>`, baseURL, baseURL, baseURL, serialNumber, profileUUID)
}
