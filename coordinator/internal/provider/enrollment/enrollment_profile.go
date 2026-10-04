package enrollment

import (
	"fmt"

	"github.com/google/uuid"
)

// generateCombinedProfile creates a .mobileconfig with two payloads:
//  1. SCEP — MDM identity certificate (for enrollment)
//  2. MDM — enrolls with MicroMDM (SecurityInfo verification)
//
// (A third ACME device-attest-01 payload existed historically, but the
// coordinator-side verification leg was never wired end-to-end and the leg was
// removed — hardware trust is earned via MDM SecurityInfo. Re-enrolling with
// this profile replaces the old one in place, dropping the dormant payload.)
//
// Display strings are branded "Darkbloom"; functional identifiers are stable so
// re-enrolls update in place: the io.darkbloom.enroll* PayloadIdentifiers +
// SCEP/MDM PayloadUUIDs (macOS keys profile identity on these), and the MDM push
// Topic (tied to the APNs cert). No identifier contains device identity.
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
func Profile(baseURL string) string {
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
  <string>io.darkbloom.enroll</string>
  <key>PayloadOrganization</key>
  <string>Darkbloom</string>
  <key>PayloadType</key>
  <string>Configuration</string>
  <key>PayloadUUID</key>
  <string>%s</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
</dict>
</plist>`, baseURL, baseURL, baseURL, profileUUID)
}
