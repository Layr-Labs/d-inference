package store

import (
	"context"
	"encoding/json"
	"errors"
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
			mdaOnlySerial := "MDA-ONLY-" + uniqueID(name)
			if err := backend.UpsertProvider(ctx, ProviderRecord{
				ID: uniqueID("provider"), SerialNumber: serial,
				Hardware: json.RawMessage(`{"memory_gb":16}`), Models: json.RawMessage(`[]`),
				Backend: "mlx-swift", TrustLevel: "hardware", MDAVerified: true,
				RegisteredAt: time.Now(), LastSeen: time.Now(),
			}); err != nil {
				t.Fatalf("seed provider: %v", err)
			}
			if err := backend.UpsertProvider(ctx, ProviderRecord{
				ID: uniqueID("mda-only"), SerialNumber: mdaOnlySerial,
				Hardware: json.RawMessage(`{"memory_gb":16}`), Models: json.RawMessage(`[]`),
				Backend: "mlx-swift", TrustLevel: "self_signed", MDAVerified: true,
				RegisteredAt: time.Now(), LastSeen: time.Now(),
			}); err != nil {
				t.Fatalf("seed MDA-only provider: %v", err)
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
			admission, err := backend.GetHardwareAdmission(ctx, serial)
			if err != nil || admission == nil ||
				admission.SerialNumber != strings.ToUpper(serial) ||
				admission.Hardware.MemoryGB != 16 {
				t.Fatalf("grandfather admission = (%+v,%v)", admission, err)
			}
			if admitted, err := backend.IsHardwareAdmitted(
				ctx, mdaOnlySerial); err != nil || admitted {
				t.Fatalf("MDA-only grandfather = (%v,%v), want false,nil", admitted, err)
			}
			admissions, err := backend.ListHardwareAdmissions(ctx, 10)
			if err != nil || len(admissions) != 1 || admissions[0].SerialNumber != strings.ToUpper(serial) {
				t.Fatalf("admissions = (%+v,%v)", admissions, err)
			}
			if admissions[0].Hardware.MemoryGB != 16 {
				t.Fatalf("grandfathered hardware = %+v, want memory_gb 16",
					admissions[0].Hardware)
			}
			if err := backend.RevokeHardwareAdmission(ctx, serial, "test-admin", "retired"); err != nil {
				t.Fatalf("revoke admission: %v", err)
			}
			if admitted, _ := backend.IsHardwareAdmitted(ctx, serial); admitted {
				t.Fatal("revoked serial remained admitted")
			}
			if revoked, err := backend.IsHardwareAdmissionRevoked(ctx, serial); err != nil || !revoked {
				t.Fatalf("revocation state = (%v,%v), want true,nil", revoked, err)
			}
			admission, err = backend.GetHardwareAdmission(ctx, serial)
			if err != nil || admission == nil || admission.RevokedAt == nil {
				t.Fatalf("revoked admission = (%+v,%v)", admission, err)
			}
			if err := backend.AdmitHardware(ctx, HardwareAdmission{
				SerialNumber: serial, PolicyVersion: enforce.Version,
			}); !errors.Is(err, ErrHardwareAdmissionRevoked) {
				t.Fatalf("re-admit revoked serial error = %v", err)
			}
			if err := backend.RestoreHardwareAdmission(ctx, serial, "test-admin", "mistake corrected"); err != nil {
				t.Fatalf("restore admission: %v", err)
			}
			if admitted, _ := backend.IsHardwareAdmitted(ctx, serial); !admitted {
				t.Fatal("restored serial did not regain admission")
			}
			if revoked, err := backend.IsHardwareAdmissionRevoked(ctx, serial); err != nil || revoked {
				t.Fatalf("restored revocation state = (%v,%v), want false,nil", revoked, err)
			}

			active, err := backend.GetActiveHardwareAdmissionPolicy(ctx)
			if err != nil || active == nil || active.Version != enforce.Version {
				t.Fatalf("active policy = (%+v,%v)", active, err)
			}
		})
	}
}

func TestFirstEnforcementGrandfathersLiveTrustedMachine(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			serial := "LIVE-" + uniqueID(name)
			enforce, err := backend.ActivateHardwareAdmissionPolicy(
				ctx,
				hardwareadmission.Policy{
					Mode: hardwareadmission.ModeEnforce, MinMemoryGB: 32,
					CatalogVersion: hardwareadmission.CatalogVersion,
				},
				0,
				HardwareAdmission{
					SerialNumber: serial,
					Hardware:     hardwareadmission.Observed{MemoryGB: 16},
				},
			)
			if err != nil {
				t.Fatalf("activate enforce: %v", err)
			}
			if enforce.GrandfatheredProviderCount != 1 {
				t.Fatalf("grandfathered count = %d, want 1",
					enforce.GrandfatheredProviderCount)
			}
			if admitted, err := backend.IsHardwareAdmitted(ctx, serial); err != nil || !admitted {
				t.Fatalf("live grandfather admission = (%v,%v), want true,nil", admitted, err)
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

func TestHardwareAdmissionRejectsStalePolicyCommit(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			first, err := backend.ActivateHardwareAdmissionPolicy(
				ctx,
				hardwareadmission.Policy{
					Mode: hardwareadmission.ModeShadow, CatalogVersion: hardwareadmission.CatalogVersion,
				},
				0,
			)
			if err != nil {
				t.Fatal(err)
			}
			_, err = backend.ActivateHardwareAdmissionPolicy(
				ctx,
				hardwareadmission.Policy{
					Mode: hardwareadmission.ModeEnforce, MinMemoryGB: 16,
					CatalogVersion: hardwareadmission.CatalogVersion,
				},
				first.Version,
			)
			if err != nil {
				t.Fatal(err)
			}
			err = backend.AdmitHardware(ctx, HardwareAdmission{
				SerialNumber:  "STALE-POLICY-" + name,
				PolicyVersion: first.Version,
			})
			if !errors.Is(err, ErrHardwareAdmissionPolicyConflict) {
				t.Fatalf("stale policy admission error = %v", err)
			}
		})
	}
}

func TestHardwareAdmissionStoreRejectsThresholdlessEnforcement(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			_, err := backend.ActivateHardwareAdmissionPolicy(
				context.Background(),
				hardwareadmission.Policy{
					Mode:           hardwareadmission.ModeEnforce,
					CatalogVersion: hardwareadmission.CatalogVersion,
				},
				0,
			)
			if err == nil {
				t.Fatal("store activated enforce mode without a capacity threshold")
			}
		})
	}
}

func TestMemoryHardwarePolicyActivationRollsBackDecodeFailure(t *testing.T) {
	st := NewMemory(Config{})
	now := time.Now()
	for _, record := range []ProviderRecord{
		{
			ID: "a-valid", SerialNumber: "ATOMIC-VALID",
			Hardware: json.RawMessage(`{"memory_gb":64}`),
			Models:   json.RawMessage(`[]`), Backend: "mlx-swift",
			TrustLevel: "hardware", RegisteredAt: now, LastSeen: now,
		},
		{
			ID: "z-invalid", SerialNumber: "ATOMIC-INVALID",
			Hardware: json.RawMessage(`{"memory_gb":`),
			Models:   json.RawMessage(`[]`), Backend: "mlx-swift",
			TrustLevel: "hardware", RegisteredAt: now, LastSeen: now,
		},
	} {
		if err := st.UpsertProvider(context.Background(), record); err != nil {
			t.Fatal(err)
		}
	}

	if _, err := st.ActivateHardwareAdmissionPolicy(
		context.Background(),
		hardwareadmission.Policy{
			Mode:           hardwareadmission.ModeEnforce,
			MinMemoryGB:    32,
			CatalogVersion: hardwareadmission.CatalogVersion,
		},
		0,
	); err == nil {
		t.Fatal("malformed grandfather hardware did not fail activation")
	}
	active, err := st.GetActiveHardwareAdmissionPolicy(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if active != nil {
		t.Fatalf("failed activation published policy %+v", active)
	}
	admissions, err := st.ListHardwareAdmissions(context.Background(), 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(admissions) != 0 {
		t.Fatalf("failed activation partially admitted %+v", admissions)
	}
}

func TestPostgresHardwareAdmissionAttemptsRemainBounded(t *testing.T) {
	databaseURL := newWithdrawableTestDatabase(t)
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	st, err := NewPostgres(ctx, Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	if _, err := st.pool.Exec(ctx, `
		INSERT INTO hardware_admission_attempts (
			provider_id, serial_number, account_id, policy_version, mode,
			decision, reason_code, hardware, failed_checks, created_at
		)
		SELECT
			'provider-' || value, '', '', 1, 'enforce',
			'rejected', 'hardware_below_minimum', '{}'::jsonb, '[]'::jsonb, NOW()
		FROM generate_series(1, 100099) AS value
	`); err != nil {
		t.Fatal(err)
	}
	if err := st.RecordHardwareAdmissionAttempt(ctx, HardwareAdmissionAttempt{
		ProviderID: "prune-trigger", PolicyVersion: 1,
		Mode: hardwareadmission.ModeEnforce, Decision: "rejected",
		ReasonCode: "hardware_below_minimum",
	}); err != nil {
		t.Fatal(err)
	}

	var count int
	if err := st.pool.QueryRow(ctx,
		`SELECT COUNT(*) FROM hardware_admission_attempts`).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != hardwareAdmissionAttemptMaxEntries {
		t.Fatalf("attempt rows = %d, want %d",
			count, hardwareAdmissionAttemptMaxEntries)
	}
}
