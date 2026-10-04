package command

import (
	"bytes"
	"fmt"
	"regexp"
)

// commandUUIDRe extracts the CommandUUID from a MicroMDM device response plist
// (<key>CommandUUID</key><string>…</string>), tolerating whitespace/newlines.
var commandUUIDRe = regexp.MustCompile(`<key>CommandUUID</key>\s*<string>([^<]+)</string>`)

// parseCommandUUID returns the CommandUUID embedded in a device response plist,
// or "" if absent.
func ParseUUID(plistData []byte) string {
	m := commandUUIDRe.FindSubmatch(plistData)
	if len(m) < 2 {
		return ""
	}
	return string(bytes.TrimSpace(m[1]))
}

// readOnlyMDMRequestTypes is the EXHAUSTIVE allowlist of MDM command request
// types the coordinator is permitted to send to a provider's Mac. Both are pure
// queries — they read security posture and never mutate the device:
//
//	SecurityInfo      → SIP / Secure Boot / FileVault status
//	DeviceInformation → DevicePropertiesAttestation (Apple-signed cert chain)
//
// Every command that could act ON a provider's machine — DeviceLock,
// EraseDevice, RestartDevice, ShutDownDevice, InstallProfile, RemoveProfile,
// InstallApplication, ClearPasscode, EnableRemoteDesktop, ScheduleOSUpdate, … —
// is intentionally absent. Enrolling a provider grants the coordinator
// read-only visibility into hardware trust, NEVER control. assertReadOnlyCommand
// is the single chokepoint that enforces this: a future code path (or a
// compromised coordinator) that tries to issue a mutating command fails closed
// here instead of reaching the device. To add a command type, it must be a
// read-only query AND added here in review.
var readOnlyMDMRequestTypes = map[string]struct{}{
	"SecurityInfo":      {},
	"DeviceInformation": {},
}

// ErrMutatingCommandBlocked is returned when something attempts to send an MDM
// command that is not on the read-only allowlist.
var ErrMutatingCommandBlocked = fmt.Errorf("mdm: refusing to send non-read-only command (provider machines are read-only)")

// assertReadOnlyCommand fails closed unless requestType is a known read-only
// query. This is the guarantee that the coordinator can never "do something" to
// a provider's Mac via MDM.
func AssertReadOnly(requestType string) error {
	if _, ok := readOnlyMDMRequestTypes[requestType]; !ok {
		return fmt.Errorf("%w: %q", ErrMutatingCommandBlocked, requestType)
	}
	return nil
}
