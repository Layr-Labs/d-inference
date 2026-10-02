//go:build native_pair_hardware_experiment

package registry

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"testing"
	"time"
)

func TestNativePairHardwareSelectionUsesActualCurrentTrust(t *testing.T) {
	f := newNativePairFixture(t)
	var devices [2]NativeHardwareDevice
	for rank, p := range f.p {
		p.mu.Lock()
		a := p.AttestationResult
		h := sha256.Sum256([]byte(a.PublicKey))
		devices[rank] = NativeHardwareDevice{a.SerialNumber, hex.EncodeToString(h[:])}
		p.mu.Unlock()
	}
	ready := func() bool {
		members, ok := f.c.HardwareSelectedMembers(devices, f.policy.ID)
		return ok && members == f.p
	}
	if !ready() {
		t.Fatal("qualified fixture not observable")
	}
	f.p[0].mu.Lock()
	f.p[0].FreshCodeAttested = false
	f.p[0].mu.Unlock()
	if ready() {
		t.Fatal("observation bypassed code trust")
	}
	f.p[0].mu.Lock()
	f.p[0].FreshCodeAttested = true
	f.p[0].mu.Unlock()
	if !ready() {
		t.Fatal("read-only check changed pair")
	}
	f.c.Detach(f.n[0])
	if ready() {
		t.Fatal("detached Provider selected")
	}
}

func TestNativePairHardwareObservationRequiresActualBilateralPublication(t *testing.T) {
	f, s, d := protectedWorkerFixture(t, true)
	for rank := range f.n {
		p := workerFixturePacket(1, d, 0, []byte("fixture-ready"))
		if e := f.c.Handle(f.n[rank], f.signed(t, s, rank, protocol.TypeNativePairWorkerReady, p)); e != nil {
			t.Fatal(e)
		}
	}
	f.read(t, 0, protocol.TypeNativePairWorkerReady)
	v := s.HardwareObservation()
	if v.ReleasedNormally() || v.ProviderIDs != [2]string{f.p[0].ID, f.p[1].ID} || v.StartSHA256[0] == v.StartSHA256[1] {
		t.Fatal("incorrect active observation")
	}
	f.c.Cancel(s)
	for rank := range f.n {
		f.read(t, rank, protocol.TypeNativePairCancel)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if e := s.WaitControlStopped(ctx); e != nil {
		t.Fatal(e)
	}
	if s.HardwareObservation().ReleasedNormally() {
		t.Fatal("Done or relay join became owner proof")
	}
	for rank := range f.n {
		if e := f.c.Handle(f.n[rank], f.signed(t, s, rank, protocol.TypeNativePairOwnerReleased, nativePairReleaseReceipt(s.starts[rank]))); e != nil {
			t.Fatal(e)
		}
		if rank == 0 && s.HardwareObservation().ReleasedNormally() {
			t.Fatal("unilateral release became success")
		}
	}
	for rank := range f.n {
		f.read(t, rank, protocol.TypeNativePairWorkersReleased)
	}
	f.c.mu.Lock()
	done := s.workerReleaseDone
	f.c.mu.Unlock()
	select {
	case <-done:
	case <-ctx.Done():
		t.Fatal("publication incomplete")
	}
	v = s.HardwareObservation()
	if !v.ReleasedNormally() {
		t.Fatalf("actual release not observed: %+v", v)
	}
	// Copied scalar observation has no release authority and cannot alter the
	// retained original handle. No synthetic flag is written into the runtime.
	v.Released[0] = false
	if v.ReleasedNormally() || !s.HardwareObservation().ReleasedNormally() {
		t.Fatal("observation alias")
	}
	f.c.Detach(f.n[0])
	if !s.HardwareObservation().ReleasedNormally() {
		t.Fatal("later disconnect erased actual publication outcome")
	}
}

func TestNativePairHardwarePublicationFailureIsRetained(t *testing.T) {
	f, s, d := protectedWorkerFixture(t, true)
	for rank := range f.n {
		p := workerFixturePacket(1, d, 0, []byte("fixture-ready"))
		if e := f.c.Handle(f.n[rank], f.signed(t, s, rank, protocol.TypeNativePairWorkerReady, p)); e != nil {
			t.Fatal(e)
		}
	}
	f.read(t, 0, protocol.TypeNativePairWorkerReady)
	f.c.Cancel(s)
	for rank := range f.n {
		f.read(t, rank, protocol.TypeNativePairCancel)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if e := s.WaitControlStopped(ctx); e != nil {
		t.Fatal(e)
	}
	f.p[1].closeWriterNow() // actual existing priority writer refuses publication
	for rank := range f.n {
		if e := f.c.Handle(f.n[rank], f.signed(t, s, rank, protocol.TypeNativePairOwnerReleased, nativePairReleaseReceipt(s.starts[rank]))); e != nil {
			t.Fatal(e)
		}
	}
	f.c.mu.Lock()
	done := s.workerReleaseDone
	f.c.mu.Unlock()
	select {
	case <-done:
	case <-ctx.Done():
		t.Fatal("publication did not retire")
	}
	v := s.HardwareObservation()
	if v.ReleasedNormally() || !v.AggregatePublicationFailed[1] || v.Released != [2]bool{true, true} {
		t.Fatal("publication failure became success or erased owner proof")
	}
}
