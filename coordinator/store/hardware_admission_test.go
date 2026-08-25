package store

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/hardwareadmission"
)

func TestHardwareAdmissionPolicyAndGrandfathering(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			serial := "LEGACY-" + uniqueID(name)
			if err := backend.UpsertProvider(ctx, ProviderRecord{
				ID: uniqueID("provider"), SerialNumber: serial,
				Hardware: json.RawMessage(`{"memory_gb":16}`), Models: json.RawMessage(`[]`),
				Backend: "mlx-swift", TrustLevel: "hardware", MDAVerified: true,
				RegisteredAt: time.Now(), LastSeen: time.Now(),
			}); err != nil {
				t.Fatalf("seed provider: %v", err)
			}

			shadow, err := backend.ActivateHardwareAdmissionPolicy(ctx, hardwareadmission.Policy{
				Mode: hardwareadmission.ModeShadow, MinMemoryGB: 32,
				CatalogVersion: hardwareadmission.CatalogVersion, CreatedBy: "test",
			}, 0)
			if err != nil {
				t.Fatalf("activate shadow: %v", err)
			}
			if shadow.Version == 0 || shadow.GrandfatherCutoffAt != nil {
				t.Fatalf("shadow policy = %+v", shadow)
			}
			if admitted, err := backend.IsHardwareAdmitted(ctx, serial); err != nil || admitted {
				t.Fatalf("shadow grandfather = (%v,%v), want false,nil", admitted, err)
			}

			enforce, err := backend.ActivateHardwareAdmissionPolicy(ctx, hardwareadmission.Policy{
				Mode: hardwareadmission.ModeEnforce, MinMemoryGB: 32,
				CatalogVersion: hardwareadmission.CatalogVersion, CreatedBy: "test",
			}, shadow.Version)
			if err != nil {
				t.Fatalf("activate enforce: %v", err)
			}
			if enforce.GrandfatherCutoffAt == nil || enforce.GrandfatheredProviderCount != 1 {
				t.Fatalf("enforce policy = %+v", enforce)
			}
			if admitted, err := backend.IsHardwareAdmitted(ctx, serial); err != nil || !admitted {
				t.Fatalf("grandfather admitted = (%v,%v), want true,nil", admitted, err)
			}
			admissions, err := backend.ListHardwareAdmissions(ctx, 10)
			if err != nil || len(admissions) != 1 || admissions[0].SerialNumber != strings.ToUpper(serial) {
				t.Fatalf("admissions = (%+v,%v)", admissions, err)
			}

			active, err := backend.GetActiveHardwareAdmissionPolicy(ctx)
			if err != nil || active == nil || active.Version != enforce.Version {
				t.Fatalf("active policy = (%+v,%v)", active, err)
			}
		})
	}
}

func TestHardwareAdmissionAttemptRoundTrip(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			policy, err := backend.ActivateHardwareAdmissionPolicy(ctx, hardwareadmission.Policy{
				Mode: hardwareadmission.ModeShadow, CatalogVersion: hardwareadmission.CatalogVersion,
			}, 0)
			if err != nil {
				t.Fatalf("activate policy: %v", err)
			}
			attempt := HardwareAdmissionAttempt{
				ProviderID: "provider-1", SerialNumber: "serial-1", AccountID: "acct-1",
				PolicyVersion: policy.Version, Mode: policy.Mode,
				Decision: "rejected", ReasonCode: "hardware_below_minimum",
				Hardware: hardwareadmission.Observed{MemoryGB: 16},
				FailedChecks: []hardwareadmission.Failure{{
					Code: "memory_below_minimum", Metric: "memory_gb", Observed: 16, Required: 32, Unit: "GiB",
				}},
			}
			if err := backend.RecordHardwareAdmissionAttempt(ctx, attempt); err != nil {
				t.Fatalf("record attempt: %v", err)
			}
			got, err := backend.ListHardwareAdmissionAttempts(ctx, "acct-1", 10)
			if err != nil {
				t.Fatalf("list attempts: %v", err)
			}
			if len(got) != 1 || got[0].ReasonCode != attempt.ReasonCode || len(got[0].FailedChecks) != 1 {
				t.Fatalf("attempts = %+v", got)
			}
		})
	}
}
