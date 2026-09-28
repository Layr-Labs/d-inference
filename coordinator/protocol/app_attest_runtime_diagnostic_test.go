package protocol

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestAppAttestRuntimeDiagnosticsStripInvalidValuesWithoutRejectingFrame(t *testing.T) {
	now := time.Unix(1_790_000_000, 0)
	valid := AppAttestShadowPayload{Action: "ready", Result: "busy", LaunchSession: "background", BootTime: now.Add(-time.Hour).Unix(), OperationStalledSeconds: 86400}
	got := valid
	got.SanitizeRuntimeDiagnostics(now)
	if !reflect.DeepEqual(got, valid) {
		t.Fatalf("valid diagnostics changed: %+v", got)
	}
	if fields := valid.RuntimeDiagnosticFields(now); !reflect.DeepEqual(fields, map[string]any{"launch_session": "background", "boot_time": valid.BootTime, "operation_stalled_seconds": 86400}) {
		t.Fatalf("fields %v", fields)
	}
	for name, tc := range map[string]struct {
		in   AppAttestShadowPayload
		want AppAttestShadowPayload
	}{
		"unknown launch label": {AppAttestShadowPayload{Action: "ready", Result: "ok", LaunchSession: "/Users/private", BootTime: 1_700_000_000},
			AppAttestShadowPayload{Action: "ready", Result: "ok", BootTime: 1_700_000_000}},
		"boot before 2020": {AppAttestShadowPayload{Action: "ready", Result: "ok", LaunchSession: "gui", BootTime: 1},
			AppAttestShadowPayload{Action: "ready", Result: "ok", LaunchSession: "gui"}},
		"boot in the future": {AppAttestShadowPayload{Action: "ready", Result: "ok", BootTime: now.Add(48 * time.Hour).Unix()},
			AppAttestShadowPayload{Action: "ready", Result: "ok"}},
		"stall without busy": {AppAttestShadowPayload{Action: "ready", Result: "apple_error", OperationStalledSeconds: 30},
			AppAttestShadowPayload{Action: "ready", Result: "apple_error"}},
		"stall above one day": {AppAttestShadowPayload{Action: "ready", Result: "busy", OperationStalledSeconds: 86401},
			AppAttestShadowPayload{Action: "ready", Result: "busy"}},
		"negative stall": {AppAttestShadowPayload{Action: "ready", Result: "busy", OperationStalledSeconds: -5},
			AppAttestShadowPayload{Action: "ready", Result: "busy"}},
		"not a ready reply": {AppAttestShadowPayload{Action: "assertion", Result: "busy", LaunchSession: "gui", BootTime: 1_700_000_000, OperationStalledSeconds: 5},
			AppAttestShadowPayload{Action: "assertion", Result: "busy"}},
	} {
		got := tc.in
		got.SanitizeRuntimeDiagnostics(now)
		if !reflect.DeepEqual(got, tc.want) {
			t.Fatalf("%s: %+v, want %+v", name, got, tc.want)
		}
		if fields := tc.in.RuntimeDiagnosticFields(now); !reflect.DeepEqual(fields, tc.want.RuntimeDiagnosticFields(now)) {
			t.Fatalf("%s: unsanitized value exported: %v", name, fields)
		}
	}
	body, err := json.Marshal(AppAttestShadowPayload{Action: "ready", Session: "session"})
	if err != nil || strings.Contains(string(body), "launch_session") || strings.Contains(string(body), "boot_time") || strings.Contains(string(body), "operation_stalled_seconds") {
		t.Fatalf("optional diagnostics changed old wire encoding: %s, %v", body, err)
	}
	var decoded AppAttestShadowPayload
	if err := json.Unmarshal([]byte(`{"action":"ready","session":"s","result":"busy","launch_session":"gui","boot_time":1700000000,"operation_stalled_seconds":42}`), &decoded); err != nil ||
		decoded.LaunchSession != "gui" || decoded.BootTime != 1_700_000_000 || decoded.OperationStalledSeconds != 42 {
		t.Fatalf("provider wire names not decoded: %+v %v", decoded, err)
	}
}
