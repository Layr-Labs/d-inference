package protocol

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
	"time"
)

func deepBool(v bool) *bool  { return &v }
func deepInt(v int) *int     { return &v }
func deepAge(v int64) *int64 { return &v }
func deepNow() time.Time     { return time.Unix(1_790_000_000, 0) }
func deepReady() AppAttestShadowPayload {
	now := deepNow()
	return AppAttestShadowPayload{Action: "ready", Result: "unsupported",
		ProcessStartedAt: now.Add(-time.Minute).Unix(), PreviousExit: "unclean", StartReason: "watchdog",
		ConsoleUserActive: deepBool(false), SIPEnabled: deepBool(true), AuthenticatedRoot: deepBool(false),
		Preflight: &AppAttestPreflight{OptInEntitlement: deepBool(true), EnvironmentEntitlement: "production",
			ProfilePresent: deepBool(true), ProfileExpired: deepBool(false), BundlePathClass: "user_install"},
		KeyHistory: &AppAttestKeyHistory{GenerationsLast24h: deepInt(100), LastGenerationAgeSeconds: deepAge(0),
			LastSuccessAgeSeconds: deepAge(3600), ConsecutiveAssertionFailures: deepInt(1000), KeyAgeSeconds: deepAge(10 * 365 * 24 * 3600),
			CreatedBootMatches: deepBool(false), CreatedAppVersion: "0.9.10-beta.1+build.7"},
		PushHistory: &AppAttestPushHistory{DeviceTokenPresent: deepBool(true), PushesReceivedLast24h: deepInt(1000),
			LastPushReceivedAgeSeconds: deepAge(0), LastReplySentAgeSeconds: deepAge(10 * 365 * 24 * 3600)}}
}

func TestDeepDiagnosticsValidReadyValuesKept(t *testing.T) {
	now := deepNow()
	in := deepReady()
	got := in
	got.SanitizeRuntimeDiagnostics(now)
	if !reflect.DeepEqual(got, in) {
		t.Fatalf("valid diagnostics changed:\n%+v\nwant %+v", got, in)
	}
	fields := in.RuntimeDiagnosticFields(now)
	for key, want := range map[string]any{"process_started_at": in.ProcessStartedAt, "previous_exit": "unclean", "start_reason": "watchdog",
		"console_user_active": false, "sip_enabled": true, "authenticated_root": false, "preflight": in.Preflight, "key_history": in.KeyHistory, "push_history": in.PushHistory} {
		if !reflect.DeepEqual(fields[key], want) {
			t.Fatalf("%s = %#v, want %#v", key, fields[key], want)
		}
	}
}

func TestDeepDiagnosticsInvalidMembersStrippedIndependently(t *testing.T) {
	now := deepNow()
	for name, tc := range map[string]struct {
		mutate func(*AppAttestShadowPayload)
		check  func(AppAttestShadowPayload) bool
	}{
		"process start before 2020":   {func(p *AppAttestShadowPayload) { p.ProcessStartedAt = 1_500_000_000 }, func(p AppAttestShadowPayload) bool { return p.ProcessStartedAt == 0 }},
		"process start in the future": {func(p *AppAttestShadowPayload) { p.ProcessStartedAt = now.Add(25 * time.Hour).Unix() }, func(p AppAttestShadowPayload) bool { return p.ProcessStartedAt == 0 }},
		"unknown previous exit":       {func(p *AppAttestShadowPayload) { p.PreviousExit = "crashed at /Users/x" }, func(p AppAttestShadowPayload) bool { return p.PreviousExit == "" }},
		"unknown start reason":        {func(p *AppAttestShadowPayload) { p.StartReason = "reboot" }, func(p AppAttestShadowPayload) bool { return p.StartReason == "" }},
		"unknown environment entitlement": {func(p *AppAttestShadowPayload) { p.Preflight.EnvironmentEntitlement = "sandbox" },
			func(p AppAttestShadowPayload) bool {
				return p.Preflight.EnvironmentEntitlement == "" && p.Preflight.BundlePathClass == "user_install"
			}},
		"unknown bundle path class": {func(p *AppAttestShadowPayload) { p.Preflight.BundlePathClass = "/Applications/Darkbloom.app" },
			func(p AppAttestShadowPayload) bool {
				return p.Preflight.BundlePathClass == "" && *p.Preflight.OptInEntitlement
			}},
		"generations above 100": {func(p *AppAttestShadowPayload) { p.KeyHistory.GenerationsLast24h = deepInt(101) },
			func(p AppAttestShadowPayload) bool {
				return p.KeyHistory.GenerationsLast24h == nil && *p.KeyHistory.ConsecutiveAssertionFailures == 1000
			}},
		"negative generations": {func(p *AppAttestShadowPayload) { p.KeyHistory.GenerationsLast24h = deepInt(-1) }, func(p AppAttestShadowPayload) bool { return p.KeyHistory.GenerationsLast24h == nil }},
		"failures above 1000": {func(p *AppAttestShadowPayload) { p.KeyHistory.ConsecutiveAssertionFailures = deepInt(1001) },
			func(p AppAttestShadowPayload) bool { return p.KeyHistory.ConsecutiveAssertionFailures == nil }},
		"negative generation age": {func(p *AppAttestShadowPayload) { p.KeyHistory.LastGenerationAgeSeconds = deepAge(-1) },
			func(p AppAttestShadowPayload) bool { return p.KeyHistory.LastGenerationAgeSeconds == nil }},
		"success age above ten years": {func(p *AppAttestShadowPayload) { p.KeyHistory.LastSuccessAgeSeconds = deepAge(10*365*24*3600 + 1) },
			func(p AppAttestShadowPayload) bool { return p.KeyHistory.LastSuccessAgeSeconds == nil }},
		"negative key age": {func(p *AppAttestShadowPayload) { p.KeyHistory.KeyAgeSeconds = deepAge(-5) }, func(p AppAttestShadowPayload) bool { return p.KeyHistory.KeyAgeSeconds == nil }},
		"version too long": {func(p *AppAttestShadowPayload) { p.KeyHistory.CreatedAppVersion = strings.Repeat("1", 33) },
			func(p AppAttestShadowPayload) bool {
				return p.KeyHistory.CreatedAppVersion == "" && p.KeyHistory.KeyAgeSeconds != nil
			}},
		"version with path characters": {func(p *AppAttestShadowPayload) { p.KeyHistory.CreatedAppVersion = "0.9/../x" },
			func(p AppAttestShadowPayload) bool { return p.KeyHistory.CreatedAppVersion == "" }},
		"version with whitespace": {func(p *AppAttestShadowPayload) { p.KeyHistory.CreatedAppVersion = "0.9 x" }, func(p AppAttestShadowPayload) bool { return p.KeyHistory.CreatedAppVersion == "" }},
		"pushes above 1000": {func(p *AppAttestShadowPayload) { p.PushHistory.PushesReceivedLast24h = deepInt(1001) },
			func(p AppAttestShadowPayload) bool {
				return p.PushHistory.PushesReceivedLast24h == nil && *p.PushHistory.DeviceTokenPresent && p.PushHistory.LastPushReceivedAgeSeconds != nil
			}},
		"negative pushes": {func(p *AppAttestShadowPayload) { p.PushHistory.PushesReceivedLast24h = deepInt(-1) },
			func(p AppAttestShadowPayload) bool { return p.PushHistory.PushesReceivedLast24h == nil }},
		"negative push age": {func(p *AppAttestShadowPayload) { p.PushHistory.LastPushReceivedAgeSeconds = deepAge(-1) },
			func(p AppAttestShadowPayload) bool {
				return p.PushHistory.LastPushReceivedAgeSeconds == nil && p.PushHistory.LastReplySentAgeSeconds != nil
			}},
		"reply age above ten years": {func(p *AppAttestShadowPayload) { p.PushHistory.LastReplySentAgeSeconds = deepAge(10*365*24*3600 + 1) },
			func(p AppAttestShadowPayload) bool {
				return p.PushHistory.LastReplySentAgeSeconds == nil && *p.PushHistory.PushesReceivedLast24h == 1000
			}},
		"empty push history dropped": {func(p *AppAttestShadowPayload) {
			p.PushHistory = &AppAttestPushHistory{PushesReceivedLast24h: deepInt(5000)}
		},
			func(p AppAttestShadowPayload) bool { return p.PushHistory == nil && p.KeyHistory != nil }},
		"empty preflight object dropped": {func(p *AppAttestShadowPayload) { p.Preflight = &AppAttestPreflight{BundlePathClass: "home"} },
			func(p AppAttestShadowPayload) bool { return p.Preflight == nil }},
		"native chain on ready": {func(p *AppAttestShadowPayload) { p.NativeErrorChain = []AppAttestNativeError{{Domain: "aks", Code: 1}} },
			func(p AppAttestShadowPayload) bool { return p.NativeErrorChain == nil && p.KeyHistory != nil }},
	} {
		in := deepReady()
		tc.mutate(&in)
		got := in
		got.SanitizeRuntimeDiagnostics(now)
		if !tc.check(got) {
			t.Fatalf("%s: not stripped as expected: %+v", name, got)
		}
		// Unrelated members survive.
		if got.StartReason == "" && name != "unknown start reason" || got.SIPEnabled == nil {
			t.Fatalf("%s: stripped unrelated members: %+v", name, got)
		}
		if fields := in.RuntimeDiagnosticFields(now); !reflect.DeepEqual(fields, got.RuntimeDiagnosticFields(now)) {
			t.Fatalf("%s: unsanitized value exported: %v", name, fields)
		}
	}
}

func TestDeepDiagnosticsSanitizingACopyLeavesOriginalIntact(t *testing.T) {
	in := deepReady()
	in.KeyHistory.GenerationsLast24h = deepInt(500)
	in.RuntimeDiagnosticFields(deepNow())
	if *in.KeyHistory.GenerationsLast24h != 500 {
		t.Fatal("sanitizing a copy mutated the caller's nested object")
	}
}

func TestDeepDiagnosticsMisplacedReadyFieldsStripped(t *testing.T) {
	now := deepNow()
	for _, action := range []string{"attestation", "assertion", "prepare", ""} {
		in := deepReady()
		in.Action, in.Result = action, "apple_error"
		in.SanitizeRuntimeDiagnostics(now)
		if in.ProcessStartedAt != 0 || in.PreviousExit != "" || in.StartReason != "" || in.ConsoleUserActive != nil || in.SIPEnabled != nil ||
			in.AuthenticatedRoot != nil || in.Preflight != nil || in.KeyHistory != nil || in.PushHistory != nil {
			t.Fatalf("%q: ready-only diagnostics kept: %+v", action, in)
		}
	}
}

func TestDeepDiagnosticsNativeErrorChainPlacementAndBounds(t *testing.T) {
	now := deepNow()
	chain := []AppAttestNativeError{{Domain: "devicecheck", Code: 0}, {Domain: "cryptotokenkit", Code: -3}, {Domain: "aks", Code: -536362989}, {Domain: "other", Code: 2147483647}}
	for _, tc := range []struct {
		action, result string
		keep           bool
	}{
		{"attestation", "apple_error", true}, {"assertion", "apple_error", true}, {"attestation", "apple_invalid_key", true}, {"assertion", "apple_invalid_key", true},
		{"assertion", "ok", false}, {"assertion", "busy", false}, {"ready", "apple_error", false}, {"attestation", "keychain_error", false},
	} {
		p := AppAttestShadowPayload{Action: tc.action, Result: tc.result, NativeErrorChain: chain}
		p.SanitizeRuntimeDiagnostics(now)
		if (p.NativeErrorChain != nil) != tc.keep {
			t.Fatalf("%s/%s: kept=%v want %v", tc.action, tc.result, p.NativeErrorChain != nil, tc.keep)
		}
		fields := (AppAttestShadowPayload{Action: tc.action, Result: tc.result, NativeErrorChain: chain}).RuntimeDiagnosticFields(now)
		if _, ok := fields["native_error_chain"]; ok != tc.keep {
			t.Fatalf("%s/%s: exported=%v", tc.action, tc.result, ok)
		}
	}
	for name, bad := range map[string][]AppAttestNativeError{
		"five entries":     append(append([]AppAttestNativeError{}, chain...), AppAttestNativeError{Domain: "other"}),
		"unknown domain":   {{Domain: "devicecheck"}, {Domain: "NSOSStatusErrorDomain", Code: 1}},
		"code above int32": {{Domain: "aks", Code: 2147483648}},
		"code below int32": {{Domain: "osstatus", Code: -2147483649}},
	} {
		p := AppAttestShadowPayload{Action: "assertion", Result: "apple_error", NativeErrorChain: bad}
		p.SanitizeRuntimeDiagnostics(now)
		if p.NativeErrorChain != nil {
			t.Fatalf("%s: invalid chain kept: %+v", name, p.NativeErrorChain)
		}
	}
}

func TestDeepDiagnosticsWireCompatibility(t *testing.T) {
	body, err := json.Marshal(AppAttestShadowPayload{Action: "ready", Session: "s"})
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"process_started_at", "previous_exit", "start_reason", "console_user_active", "sip_enabled", "authenticated_root", "preflight", "key_history", "push_history", "native_error_chain"} {
		if strings.Contains(string(body), key) {
			t.Fatalf("absent diagnostic %s changed old wire encoding: %s", key, body)
		}
	}
	var decoded AppAttestShadowPayload
	wire := `{"action":"ready","session":"s","result":"ok","process_started_at":1700000000,"previous_exit":"clean","start_reason":"launchd",
		"console_user_active":false,"sip_enabled":true,"authenticated_root":true,
		"preflight":{"opt_in_entitlement":true,"environment_entitlement":"development","profile_present":false,"profile_expired":true,"bundle_path_class":"applications"},
		"key_history":{"generations_last_24h":3,"last_generation_age_seconds":60,"last_success_age_seconds":0,"consecutive_assertion_failures":0,"key_age_seconds":120,"created_boot_matches":true,"created_app_version":"0.9.10"},
		"push_history":{"device_token_present":false,"pushes_received_last_24h":0,"last_push_received_age_seconds":7200,"last_reply_sent_age_seconds":0},
		"native_error_chain":[{"domain":"devicecheck","code":3}]}`
	if err := json.Unmarshal([]byte(wire), &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.ProcessStartedAt != 1_700_000_000 || decoded.PreviousExit != "clean" || decoded.StartReason != "launchd" || *decoded.ConsoleUserActive ||
		!*decoded.SIPEnabled || !*decoded.AuthenticatedRoot || decoded.Preflight.EnvironmentEntitlement != "development" || *decoded.Preflight.ProfilePresent ||
		!*decoded.Preflight.ProfileExpired || decoded.Preflight.BundlePathClass != "applications" || *decoded.KeyHistory.GenerationsLast24h != 3 ||
		*decoded.KeyHistory.LastSuccessAgeSeconds != 0 || *decoded.KeyHistory.ConsecutiveAssertionFailures != 0 || !*decoded.KeyHistory.CreatedBootMatches ||
		decoded.KeyHistory.CreatedAppVersion != "0.9.10" || *decoded.PushHistory.DeviceTokenPresent || *decoded.PushHistory.PushesReceivedLast24h != 0 ||
		*decoded.PushHistory.LastPushReceivedAgeSeconds != 7200 || *decoded.PushHistory.LastReplySentAgeSeconds != 0 || len(decoded.NativeErrorChain) != 1 || decoded.NativeErrorChain[0].Code != 3 {
		t.Fatalf("provider wire names not decoded: %+v", decoded)
	}
	// Zero values are meaningful and survive a round trip.
	round, _ := json.Marshal(decoded)
	for _, fragment := range []string{`"console_user_active":false`, `"last_success_age_seconds":0`, `"consecutive_assertion_failures":0`, `"device_token_present":false`, `"pushes_received_last_24h":0`} {
		if !strings.Contains(string(round), fragment) {
			t.Fatalf("zero value %s lost: %s", fragment, round)
		}
	}
}

func TestDeepDiagnosticsWrongJSONTypeStripsMemberNotFrame(t *testing.T) {
	wire := []byte(`{"type":"app_attest_shadow","payload":{"action":"ready","session":"s","result":"ok","key_id":"k",
		"process_started_at":"yesterday","sip_enabled":"yes","native_error_chain":{"domain":"aks"},
		"preflight":{"opt_in_entitlement":"true","bundle_path_class":"applications"},
		"key_history":{"generations_last_24h":1.5,"key_age_seconds":120,"created_app_version":7},
		"push_history":{"device_token_present":1,"pushes_received_last_24h":"many","last_push_received_age_seconds":30,"last_reply_sent_age_seconds":[]},
		"start_reason":"launchd"}}`)
	var decoded ProviderMessage
	if err := DecodeProviderMessage(wire, &decoded); err != nil {
		t.Fatalf("mistyped diagnostic dropped the frame: %v", err)
	}
	p := decoded.Payload.(*AppAttestShadowMessage).Payload
	if p.KeyID != "k" || p.StartReason != "launchd" || p.ProcessStartedAt != 0 || p.SIPEnabled != nil || p.NativeErrorChain != nil {
		t.Fatalf("wrong members kept or valid members lost: %+v", p)
	}
	if p.Preflight == nil || p.Preflight.OptInEntitlement != nil || p.Preflight.BundlePathClass != "applications" {
		t.Fatalf("preflight not stripped member-wise: %+v", p.Preflight)
	}
	if p.KeyHistory == nil || p.KeyHistory.GenerationsLast24h != nil || p.KeyHistory.CreatedAppVersion != "" || *p.KeyHistory.KeyAgeSeconds != 120 {
		t.Fatalf("key history not stripped member-wise: %+v", p.KeyHistory)
	}
	if p.PushHistory == nil || p.PushHistory.DeviceTokenPresent != nil || p.PushHistory.PushesReceivedLast24h != nil ||
		p.PushHistory.LastReplySentAgeSeconds != nil || *p.PushHistory.LastPushReceivedAgeSeconds != 30 {
		t.Fatalf("push history not stripped member-wise: %+v", p.PushHistory)
	}
	if err := DecodeProviderMessage([]byte(`{"type":"app_attest_shadow","payload":{"action":"ready","session":"s","push_history":"none"}}`), &decoded); err != nil ||
		decoded.Payload.(*AppAttestShadowMessage).Payload.PushHistory != nil {
		t.Fatalf("mistyped push_history object not stripped: %v", err)
	}
	// Non-diagnostic members keep their strict decoding.
	if err := DecodeProviderMessage([]byte(`{"type":"app_attest_shadow","payload":{"action":7}}`), &decoded); err == nil {
		t.Fatal("mistyped protocol member accepted")
	}
}
