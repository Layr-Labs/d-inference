package protocol

import (
	"encoding/json"
	"regexp"
	"time"
)

// Deep provider diagnostics explain App Attest failures that the closed error
// labels cannot: process/boot lifecycle, local security posture, signing
// preflight, local key history and the native NSError underlying chain. Every
// member is a closed enum, bounded integer, boolean or short version string.
// They are untrusted context: never part of the signed transcript, never an
// authorization input, and stripped member-by-member when invalid.
const (
	appAttestMaxDiagnosticAgeSec  = 10 * 365 * 24 * 60 * 60
	appAttestMaxKeyGenerations24h = 100
	appAttestMaxAssertionFailures = 1000
	appAttestMaxNativeErrorChain  = 4
	appAttestMaxPushesReceived24h = 1000
	appAttestMaxAppVersionLength  = 32
)

var appAttestAppVersionPattern = regexp.MustCompile(`^[0-9A-Za-z.+-]+$`)

// AppAttestPreflight is the provider's local signing/profile preflight.
// Members the provider cannot compute are omitted.
type AppAttestPreflight struct {
	OptInEntitlement       *bool  `json:"opt_in_entitlement,omitempty"`
	EnvironmentEntitlement string `json:"environment_entitlement,omitempty"`
	ProfilePresent         *bool  `json:"profile_present,omitempty"`
	ProfileExpired         *bool  `json:"profile_expired,omitempty"`
	BundlePathClass        string `json:"bundle_path_class,omitempty"`
}

// AppAttestKeyHistory is the provider's local key-generation and assertion
// history. It never carries a key ID.
type AppAttestKeyHistory struct {
	GenerationsLast24h           *int   `json:"generations_last_24h,omitempty"`
	LastGenerationAgeSeconds     *int64 `json:"last_generation_age_seconds,omitempty"`
	LastSuccessAgeSeconds        *int64 `json:"last_success_age_seconds,omitempty"`
	ConsecutiveAssertionFailures *int   `json:"consecutive_assertion_failures,omitempty"`
	KeyAgeSeconds                *int64 `json:"key_age_seconds,omitempty"`
	CreatedBootMatches           *bool  `json:"created_boot_matches,omitempty"`
	CreatedAppVersion            string `json:"created_app_version,omitempty"`
}

// AppAttestPushHistory is the provider's local record of APNs code-identity
// pushes. Compared with the coordinator's code_attest.push/push_reply metrics
// it separates pushes that never reached the Mac from pushes that arrived and
// went unanswered. It never carries the device token itself.
type AppAttestPushHistory struct {
	DeviceTokenPresent         *bool  `json:"device_token_present,omitempty"`
	PushesReceivedLast24h      *int   `json:"pushes_received_last_24h,omitempty"`
	LastPushReceivedAgeSeconds *int64 `json:"last_push_received_age_seconds,omitempty"`
	LastReplySentAgeSeconds    *int64 `json:"last_reply_sent_age_seconds,omitempty"`
}

// AppAttestNativeError is one NSError in the NSUnderlyingErrorKey chain,
// outermost first. Only a closed domain bucket and a signed 32-bit code.
type AppAttestNativeError struct {
	Domain string `json:"domain"`
	Code   int64  `json:"code"`
}

// appAttestLenientPayloadKeys are the optional diagnostic members whose wrong
// JSON type is stripped instead of failing the whole frame.
var appAttestLenientPayloadKeys = []string{
	"launch_session", "boot_time", "operation_stalled_seconds",
	"process_started_at", "previous_exit", "start_reason", "console_user_active",
	"sip_enabled", "authenticated_root", "preflight", "key_history", "push_history", "native_error_chain",
}

var appAttestLenientPreflightKeys = []string{
	"opt_in_entitlement", "environment_entitlement", "profile_present", "profile_expired", "bundle_path_class",
}

var appAttestLenientKeyHistoryKeys = []string{
	"generations_last_24h", "last_generation_age_seconds", "last_success_age_seconds",
	"consecutive_assertion_failures", "key_age_seconds", "created_boot_matches", "created_app_version",
}

var appAttestLenientPushHistoryKeys = []string{
	"device_token_present", "pushes_received_last_24h", "last_push_received_age_seconds", "last_reply_sent_age_seconds",
}

// UnmarshalJSON decodes normally; only when that fails does it drop the
// diagnostic members whose JSON type is wrong (for example a string where a
// number belongs) and decode the rest. Errors in any other member still reject
// the frame exactly as before.
func (p *AppAttestShadowPayload) UnmarshalJSON(data []byte) error {
	type plain AppAttestShadowPayload
	decoded, err := unmarshalDroppingInvalidMembers[plain](data, appAttestLenientPayloadKeys)
	*p = AppAttestShadowPayload(decoded)
	return err
}

func (p *AppAttestPreflight) UnmarshalJSON(data []byte) error {
	type plain AppAttestPreflight
	decoded, err := unmarshalDroppingInvalidMembers[plain](data, appAttestLenientPreflightKeys)
	*p = AppAttestPreflight(decoded)
	return err
}

func (h *AppAttestKeyHistory) UnmarshalJSON(data []byte) error {
	type plain AppAttestKeyHistory
	decoded, err := unmarshalDroppingInvalidMembers[plain](data, appAttestLenientKeyHistoryKeys)
	*h = AppAttestKeyHistory(decoded)
	return err
}

func (h *AppAttestPushHistory) UnmarshalJSON(data []byte) error {
	type plain AppAttestPushHistory
	decoded, err := unmarshalDroppingInvalidMembers[plain](data, appAttestLenientPushHistoryKeys)
	*h = AppAttestPushHistory(decoded)
	return err
}

// T must be a method-free alias of the target type, or this recurses.
func unmarshalDroppingInvalidMembers[T any](data []byte, keys []string) (T, error) {
	var value T
	err := json.Unmarshal(data, &value)
	if err == nil {
		return value, nil
	}
	var members map[string]json.RawMessage
	if json.Unmarshal(data, &members) != nil {
		return value, err
	}
	dropped := false
	for _, key := range keys {
		member, ok := members[key]
		if !ok {
			continue
		}
		single, _ := json.Marshal(map[string]json.RawMessage{key: member})
		var probe T
		if json.Unmarshal(single, &probe) != nil {
			delete(members, key)
			dropped = true
		}
	}
	if !dropped {
		return value, err
	}
	cleaned, _ := json.Marshal(members)
	var retry T
	return retry, json.Unmarshal(cleaned, &retry)
}

// sanitizeDeepDiagnostics clears every deep diagnostic member that is out of
// range, not in its closed set, or misplaced. It allocates replacement
// objects instead of mutating shared pointees, so sanitizing a copy never
// changes the caller's payload.
func (p *AppAttestShadowPayload) sanitizeDeepDiagnostics(now time.Time) {
	if !p.nativeErrorChainAllowed() || !validNativeErrorChain(p.NativeErrorChain) {
		p.NativeErrorChain = nil
	}
	if p.Action != "ready" {
		p.ProcessStartedAt, p.PreviousExit, p.StartReason = 0, "", ""
		p.ConsoleUserActive, p.SIPEnabled, p.AuthenticatedRoot = nil, nil, nil
		p.Preflight, p.KeyHistory, p.PushHistory = nil, nil, nil
		return
	}
	if p.ProcessStartedAt != 0 && !validAppAttestTimestamp(p.ProcessStartedAt, now) {
		p.ProcessStartedAt = 0
	}
	switch p.PreviousExit {
	case "", "clean", "unclean", "unknown":
	default:
		p.PreviousExit = ""
	}
	switch p.StartReason {
	case "", "launchd", "watchdog", "update", "stall_restart", "manual", "unknown":
	default:
		p.StartReason = ""
	}
	p.Preflight = p.Preflight.sanitized()
	p.KeyHistory = p.KeyHistory.sanitized()
	p.PushHistory = p.PushHistory.sanitized()
}

func (p AppAttestShadowPayload) nativeErrorChainAllowed() bool {
	return (p.Action == "attestation" || p.Action == "assertion") && (p.Result == "apple_error" || p.Result == "apple_invalid_key")
}

func validAppAttestTimestamp(unix int64, now time.Time) bool {
	return unix >= appAttestMinBootTime && unix <= now.Add(appAttestMaxBootTimeSkew).Unix()
}

func validNativeErrorChain(chain []AppAttestNativeError) bool {
	if len(chain) > appAttestMaxNativeErrorChain {
		return false
	}
	for _, entry := range chain {
		switch entry.Domain {
		case "devicecheck", "osstatus", "url", "cocoa", "cryptotokenkit", "aks", "other":
		default:
			return false
		}
		if entry.Code < -2147483648 || entry.Code > 2147483647 {
			return false
		}
	}
	return true
}

func (f *AppAttestPreflight) sanitized() *AppAttestPreflight {
	if f == nil {
		return nil
	}
	out := AppAttestPreflight{OptInEntitlement: f.OptInEntitlement, ProfilePresent: f.ProfilePresent, ProfileExpired: f.ProfileExpired}
	switch f.EnvironmentEntitlement {
	case "production", "development", "absent", "invalid":
		out.EnvironmentEntitlement = f.EnvironmentEntitlement
	}
	switch f.BundlePathClass {
	case "user_install", "applications", "other":
		out.BundlePathClass = f.BundlePathClass
	}
	if out == (AppAttestPreflight{}) {
		return nil
	}
	return &out
}

func (h *AppAttestKeyHistory) sanitized() *AppAttestKeyHistory {
	if h == nil {
		return nil
	}
	out := AppAttestKeyHistory{CreatedBootMatches: h.CreatedBootMatches}
	if h.GenerationsLast24h != nil && *h.GenerationsLast24h >= 0 && *h.GenerationsLast24h <= appAttestMaxKeyGenerations24h {
		out.GenerationsLast24h = h.GenerationsLast24h
	}
	if h.ConsecutiveAssertionFailures != nil && *h.ConsecutiveAssertionFailures >= 0 && *h.ConsecutiveAssertionFailures <= appAttestMaxAssertionFailures {
		out.ConsecutiveAssertionFailures = h.ConsecutiveAssertionFailures
	}
	out.LastGenerationAgeSeconds = validDiagnosticAge(h.LastGenerationAgeSeconds)
	out.LastSuccessAgeSeconds = validDiagnosticAge(h.LastSuccessAgeSeconds)
	out.KeyAgeSeconds = validDiagnosticAge(h.KeyAgeSeconds)
	if len(h.CreatedAppVersion) <= appAttestMaxAppVersionLength && appAttestAppVersionPattern.MatchString(h.CreatedAppVersion) {
		out.CreatedAppVersion = h.CreatedAppVersion
	}
	if out == (AppAttestKeyHistory{}) {
		return nil
	}
	return &out
}

func (h *AppAttestPushHistory) sanitized() *AppAttestPushHistory {
	if h == nil {
		return nil
	}
	out := AppAttestPushHistory{DeviceTokenPresent: h.DeviceTokenPresent,
		LastPushReceivedAgeSeconds: validDiagnosticAge(h.LastPushReceivedAgeSeconds),
		LastReplySentAgeSeconds:    validDiagnosticAge(h.LastReplySentAgeSeconds)}
	if h.PushesReceivedLast24h != nil && *h.PushesReceivedLast24h >= 0 && *h.PushesReceivedLast24h <= appAttestMaxPushesReceived24h {
		out.PushesReceivedLast24h = h.PushesReceivedLast24h
	}
	if out == (AppAttestPushHistory{}) {
		return nil
	}
	return &out
}

func validDiagnosticAge(age *int64) *int64 {
	if age != nil && *age >= 0 && *age <= appAttestMaxDiagnosticAgeSec {
		return age
	}
	return nil
}

// addDeepDiagnosticFields adds the already-sanitized deep diagnostics.
func (p AppAttestShadowPayload) addDeepDiagnosticFields(fields map[string]any) {
	if p.ProcessStartedAt != 0 {
		fields["process_started_at"] = p.ProcessStartedAt
	}
	if p.PreviousExit != "" {
		fields["previous_exit"] = p.PreviousExit
	}
	if p.StartReason != "" {
		fields["start_reason"] = p.StartReason
	}
	for key, value := range map[string]*bool{"console_user_active": p.ConsoleUserActive, "sip_enabled": p.SIPEnabled, "authenticated_root": p.AuthenticatedRoot} {
		if value != nil {
			fields[key] = *value
		}
	}
	if p.Preflight != nil {
		fields["preflight"] = p.Preflight
	}
	if p.KeyHistory != nil {
		fields["key_history"] = p.KeyHistory
	}
	if p.PushHistory != nil {
		fields["push_history"] = p.PushHistory
	}
	if len(p.NativeErrorChain) > 0 {
		fields["native_error_chain"] = p.NativeErrorChain
	}
}
