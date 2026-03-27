package api

import (
	"encoding/json"
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

// handleEnroll generates a per-device .mobileconfig with an ACME payload
// for device-attest-01 enrollment. The ClientIdentifier is set to the
// device's serial number so step-ca can bind the SE key to the device.
//
// No authentication required — the serial number is not secret.
// Security comes from Apple's attestation during the ACME challenge:
// step-ca validates that the device actually has a Secure Enclave and
// the serial in Apple's attestation cert matches the ClientIdentifier.
func (s *Server) handleEnroll(w http.ResponseWriter, r *http.Request) {
	var req enrollRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
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

	s.logger.Info("generating ACME enrollment profile",
		"serial_number", req.SerialNumber,
	)

	profile := generateACMEProfile(req.SerialNumber)

	w.Header().Set("Content-Type", "application/x-apple-aspen-config")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="DGInf-Enroll-%s.mobileconfig"`, req.SerialNumber))
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(profile))
}

// generateACMEProfile creates a .mobileconfig containing only the ACME
// payload for device-attest-01. This is separate from the MDM enrollment
// profile — it only handles SE key attestation.
func generateACMEProfile(serialNumber string) string {
	payloadUUID := uuid.New().String()
	profileUUID := uuid.New().String()

	// macOS generates CN as "PayloadDisplayName (SerialNumber)" in the CSR.
	// step-ca checks CN == ClientIdentifier. So we set PayloadDisplayName
	// to the serial and ClientIdentifier to "SerialNumber (SerialNumber)"
	// to match what macOS will generate as the CN.
	//
	// Actually: set PayloadDisplayName to serial so CN becomes "SERIAL (SERIAL)"
	// and ClientIdentifier to "SERIAL (SERIAL)" to match.
	//
	// Simpler: just set PayloadDisplayName to empty-ish and use serial as ClientIdentifier.
	// macOS with empty DisplayName might just use serial as CN.
	//
	// Safest: remove Subject entirely and set PayloadDisplayName = serial.
	// Then CN = "F46GTCP40H (F46GTCP40H)" and ClientIdentifier = same.

	displayName := serialNumber
	clientID := serialNumber

	return fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadType</key>
      <string>com.apple.security.acme</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
      <key>PayloadIdentifier</key>
      <string>io.dginf.acme.%s</string>
      <key>PayloadUUID</key>
      <string>%s</string>
      <key>PayloadDisplayName</key>
      <string>%s</string>
      <key>PayloadDescription</key>
      <string>Generates a hardware-bound key in the Secure Enclave and obtains an Apple-attested certificate via ACME device-attest-01.</string>
      <key>PayloadOrganization</key>
      <string>DGInf</string>
      <key>DirectoryURL</key>
      <string>https://inference-test.openinnovation.dev/acme/dginf-acme/directory</string>
      <key>ClientIdentifier</key>
      <string>%s</string>
      <key>KeySize</key>
      <integer>384</integer>
      <key>KeyType</key>
      <string>ECSECPrimeRandom</string>
      <key>HardwareBound</key>
      <true/>
      <key>Attest</key>
      <true/>
      <key>Subject</key>
      <array>
        <array>
          <array>
            <string>O</string>
            <string>DGInf Provider</string>
          </array>
        </array>
        <array>
          <array>
            <string>CN</string>
            <string>%s</string>
          </array>
        </array>
      </array>
    </dict>
  </array>
  <key>PayloadDescription</key>
  <string>DGInf Secure Enclave device attestation</string>
  <key>PayloadDisplayName</key>
  <string>DGInf Device Attestation</string>
  <key>PayloadIdentifier</key>
  <string>io.dginf.enroll.acme.%s</string>
  <key>PayloadOrganization</key>
  <string>DGInf</string>
  <key>PayloadType</key>
  <string>Configuration</string>
  <key>PayloadUUID</key>
  <string>%s</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
</dict>
</plist>`, serialNumber, payloadUUID, displayName, clientID, serialNumber, serialNumber, profileUUID)
}
