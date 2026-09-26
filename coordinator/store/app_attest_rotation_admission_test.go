package store

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

// Concurrent sessions for different dead keys on one machine must not both
// pass the per-machine limit: the window check and the insert are one step.
func TestAppAttestKeyRotationAdmissionIsAtomicPerScope(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			rotations, ok := As[AppAttestKeyRotationStore](NewCached(backend, DefaultCacheConfig()))
			if !ok {
				t.Fatal("rotation storage hidden by decorator")
			}
			scope := uniqueID("machine")
			limits := []AppAttestRotationLimit{{Window: time.Hour, Max: 1}, {Window: 24 * time.Hour, Max: 4}}
			now := time.Now().UTC().Truncate(time.Microsecond)
			const callers = 16
			var wg sync.WaitGroup
			admitted := make(chan string, callers)
			errs := make(chan error, callers)
			start := make(chan struct{})
			for i := range callers {
				wg.Add(1)
				go func(i int) {
					defer wg.Done()
					<-start
					key := fmt.Sprintf("%s-key-%d", scope, i)
					_, ok, err := rotations.AdmitAppAttestKeyRotation(t.Context(), AppAttestKeyRotation{
						KeyID: key, MachineID: scope, AccountID: "account", RequestedAt: now, Failures: 2, Reason: "assertion_apple_error",
					}, limits)
					if err != nil {
						errs <- err
						return
					}
					if ok {
						admitted <- key
					}
				}(i)
			}
			close(start)
			wg.Wait()
			close(admitted)
			close(errs)
			for err := range errs {
				t.Fatal(err)
			}
			var keys []string
			for k := range admitted {
				keys = append(keys, k)
			}
			if len(keys) != 1 {
				t.Fatalf("concurrent admissions for one machine: %d admitted, want exactly 1 (%v)", len(keys), keys)
			}
			if n, err := rotations.CountAppAttestKeyRotations(t.Context(), scope, now.Add(-time.Hour)); err != nil || n != 1 {
				t.Fatalf("stored rotations in the hour = %d (%v), want 1", n, err)
			}
			// The admitted key is returned as existing on a repeat request,
			// without an insert, even though the hourly window is full.
			existing, ok, err := rotations.AdmitAppAttestKeyRotation(t.Context(), AppAttestKeyRotation{
				KeyID: keys[0], MachineID: scope, AccountID: "account", RequestedAt: now.Add(time.Minute), Failures: 3, Reason: "assertion_apple_error",
			}, limits)
			if err != nil || ok || existing == nil || !existing.RequestedAt.Equal(now) {
				t.Fatalf("repeat request for the admitted key: existing=%+v admitted=%v err=%v", existing, ok, err)
			}
			// A different machine is not affected by this one's window.
			if _, ok, err := rotations.AdmitAppAttestKeyRotation(t.Context(), AppAttestKeyRotation{
				KeyID: scope + "-other", MachineID: scope + "-other-machine", AccountID: "account", RequestedAt: now, Failures: 2, Reason: "assertion_apple_error",
			}, limits); err != nil || !ok {
				t.Fatalf("other machine blocked: admitted=%v err=%v", ok, err)
			}
		})
	}
}

// A rotation row keeps the machine that was canonical when it was recorded.
// When that machine is later merged into another, the survivor's limits must
// still count the row, or the same Mac gets another immediate rotation.
func TestAppAttestKeyRotationLimitsSurviveMachineMerges(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			inventory, _ := As[MachineInventoryStore](backend)
			lookup, _ := As[MachineIdentityLookupStore](backend)
			rotations, ok := As[AppAttestKeyRotationStore](NewCached(backend, DefaultCacheConfig()))
			if !ok || inventory == nil || lookup == nil {
				t.Fatal("inventory or rotation storage hidden")
			}
			account, serial, now := uniqueID("account"), uniqueID("serial"), time.Now().UTC().Truncate(time.Microsecond)
			observe := func(session, se, verifiedSerial string) string {
				t.Helper()
				id, err := inventory.ObserveMachine(t.Context(), MachineObservation{SessionID: session, AccountID: account, SEKey: se,
					VerifiedSerial: verifiedSerial, At: now, OSMajor: 27, Source: "live_registration"})
				if err != nil {
					t.Fatal(err)
				}
				return id.ID
			}
			limits := []AppAttestRotationLimit{{Window: time.Hour, Max: 1}, {Window: 24 * time.Hour, Max: 4}}
			admit := func(scope string, at time.Time) bool {
				t.Helper()
				_, ok, err := rotations.AdmitAppAttestKeyRotation(t.Context(), AppAttestKeyRotation{KeyID: uniqueID("key"), MachineID: scope,
					AccountID: account, RequestedAt: at, Failures: 2, Reason: "assertion_apple_error"}, limits)
				if err != nil {
					t.Fatal(err)
				}
				return ok
			}
			survivor := observe(uniqueID("a"), uniqueID("se"), serial)
			sessionB, seB := uniqueID("b"), uniqueID("se")
			predecessor := observe(sessionB, seB, "")
			if predecessor == survivor {
				t.Fatal("fixture machines collapsed before the merge")
			}
			if !admit(predecessor, now) {
				t.Fatal("first rotation for the machine not admitted")
			}
			// The same Apple-verified serial proves both records are one Mac.
			if observe(sessionB, seB, serial) != survivor {
				t.Fatal("verified serial did not merge the machines")
			}
			if canonical, err := lookup.CanonicalMachineID(t.Context(), predecessor); err != nil || canonical != survivor {
				t.Fatalf("canonical of merged machine = %q (%v), want %q", canonical, err, survivor)
			}
			if admit(survivor, now.Add(time.Minute)) {
				t.Fatal("merge reset the hourly rotation limit")
			}
			if n, err := rotations.CountAppAttestKeyRotations(t.Context(), survivor, now.Add(-time.Hour)); err != nil || n != 1 {
				t.Fatalf("survivor rotations in the hour = %d (%v), want 1", n, err)
			}
			if !admit(survivor, now.Add(time.Hour+time.Minute)) {
				t.Fatal("rotation blocked after the hourly window passed")
			}
		})
	}
}
