package mdm

import (
	"bytes"
	"encoding/base64"
	"regexp"
)

// commandUUIDRe extracts the CommandUUID from a MicroMDM device response plist
// (<key>CommandUUID</key><string>…</string>), tolerating whitespace/newlines.
var commandUUIDRe = regexp.MustCompile(`<key>CommandUUID</key>\s*<string>([^<]+)</string>`)

// parseCommandUUID returns the CommandUUID embedded in a device response plist,
// or "" if absent.
func parseCommandUUID(plistData []byte) string {
	m := commandUUIDRe.FindSubmatch(plistData)
	if len(m) < 2 {
		return ""
	}
	return string(bytes.TrimSpace(m[1]))
}

// parseSecurityInfoPlist extracts security fields from the MDM response plist.
func parseSecurityInfoPlist(data []byte) *SecurityInfoResponse {
	// MDM responses are Apple plist XML. Parse the relevant fields.

	// Simple approach: look for known keys in the XML
	result := &SecurityInfoResponse{}
	found := bytes.Contains(data, []byte("SecurityInfo"))

	if bytes.Contains(data, []byte("<key>SystemIntegrityProtectionEnabled</key>")) {
		result.SystemIntegrityProtectionEnabled = bytes.Contains(data, []byte("<key>SystemIntegrityProtectionEnabled</key>\n\t\t<true/>")) ||
			bytes.Contains(data, []byte("<key>SystemIntegrityProtectionEnabled</key>\r\n\t\t<true/>")) ||
			bytes.Contains(data, []byte("SystemIntegrityProtectionEnabled</key>\n\t<true")) ||
			bytes.Contains(data, []byte("SystemIntegrityProtectionEnabled</key><true"))
		found = true
	}
	if bytes.Contains(data, []byte("<key>AuthenticatedRootVolumeEnabled</key>")) {
		result.AuthenticatedRootVolumeEnabled = bytes.Contains(data, []byte("AuthenticatedRootVolumeEnabled</key>\n\t\t<true")) ||
			bytes.Contains(data, []byte("AuthenticatedRootVolumeEnabled</key><true"))
		found = true
	}
	if bytes.Contains(data, []byte("<key>FDE_Enabled</key>")) {
		result.FileVaultEnabled = bytes.Contains(data, []byte("FDE_Enabled</key>\n\t\t<true")) ||
			bytes.Contains(data, []byte("FDE_Enabled</key><true"))
		found = true
	}
	if bytes.Contains(data, []byte("<key>IsRecoveryLockEnabled</key>")) {
		result.IsRecoveryLockEnabled = bytes.Contains(data, []byte("IsRecoveryLockEnabled</key>\n\t\t<true")) ||
			bytes.Contains(data, []byte("IsRecoveryLockEnabled</key>\n\t<true")) ||
			bytes.Contains(data, []byte("IsRecoveryLockEnabled</key><true"))
		found = true
	}

	// Parse SecureBoot level
	if idx := bytes.Index(data, []byte("<key>SecureBootLevel</key>")); idx >= 0 {
		rest := data[idx:]
		if sIdx := bytes.Index(rest, []byte("<string>")); sIdx >= 0 {
			rest = rest[sIdx+8:]
			if eIdx := bytes.Index(rest, []byte("</string>")); eIdx >= 0 {
				result.SecureBootLevel = string(rest[:eIdx])
				found = true
			}
		}
	}

	if !found {
		return nil
	}
	return result
}

// parseDeviceAttestationPlist extracts the DER certificate chain from a
// DeviceInformation response containing DevicePropertiesAttestation.
//
// The plist format is:
//
//	<key>DevicePropertiesAttestation</key>
//	<array>
//	  <data>...base64 DER cert...</data>
//	  <data>...base64 DER cert...</data>
//	</array>
func parseDeviceAttestationPlist(data []byte) [][]byte {
	// Find DevicePropertiesAttestation key
	marker := []byte("<key>DevicePropertiesAttestation</key>")
	idx := bytes.Index(data, marker)
	if idx < 0 {
		return nil
	}

	rest := data[idx+len(marker):]

	// Find the <array> element
	arrStart := bytes.Index(rest, []byte("<array>"))
	if arrStart < 0 {
		return nil
	}
	rest = rest[arrStart:]

	arrEnd := bytes.Index(rest, []byte("</array>"))
	if arrEnd < 0 {
		return nil
	}
	arrayContent := rest[:arrEnd]

	// Extract all <data>...</data> elements
	var certs [][]byte
	remaining := arrayContent
	for {
		dataStart := bytes.Index(remaining, []byte("<data>"))
		if dataStart < 0 {
			break
		}
		remaining = remaining[dataStart+6:]

		dataEnd := bytes.Index(remaining, []byte("</data>"))
		if dataEnd < 0 {
			break
		}

		// Strip ALL whitespace (tabs, newlines) from the base64 data —
		// Apple's plist format includes formatting whitespace inside <data> tags.
		raw := bytes.TrimSpace(remaining[:dataEnd])
		var cleaned []byte
		for _, b := range raw {
			if b != '\n' && b != '\r' && b != '\t' && b != ' ' {
				cleaned = append(cleaned, b)
			}
		}
		b64Data := string(cleaned)
		remaining = remaining[dataEnd+7:]

		// Decode base64 to get DER bytes
		derBytes, err := base64.StdEncoding.DecodeString(b64Data)
		if err != nil {
			continue
		}
		certs = append(certs, derBytes)
	}

	if len(certs) == 0 {
		return nil
	}
	return certs
}
