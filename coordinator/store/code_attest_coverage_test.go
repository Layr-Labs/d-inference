package store

import (
	"context"
	"testing"
	"time"
)

type codeCoverageBackend interface {
	Store
	AdvanceCodeAttestationCoverage(context.Context, []CodeAttestation) error
}

func codeCoverageContract(t *testing.T, s codeCoverageBackend) {
	t.Helper()
	ctx := context.Background()
	at := time.Date(2026, 9, 8, 0, 0, 0, 123456000, time.UTC)
	proof := CodeAttestation{SEPubKey: "se-coverage", Version: "0.9.0", APNsToken: "token", NodePublicKey: "process", BinaryHash: "binary", AttestedAt: at}
	until := at.Add(time.Hour)
	observation := proof
	observation.ContinuousCoverageUntil = &until
	if err := s.AdvanceCodeAttestationCoverage(ctx, []CodeAttestation{observation}); err != nil {
		t.Fatal(err)
	}
	rows, _ := s.ListCodeAttestations(ctx)
	if len(rows) != 0 {
		t.Fatal("coverage inserted proof")
	}
	if err := s.UpsertCodeAttestation(ctx, proof); err != nil {
		t.Fatal(err)
	}
	if err := s.AdvanceCodeAttestationCoverage(ctx, []CodeAttestation{observation}); err != nil {
		t.Fatal(err)
	}
	rows, _ = s.ListCodeAttestations(ctx)
	if len(rows) != 1 || rows[0].ContinuousCoverageUntil == nil || !rows[0].ContinuousCoverageUntil.Equal(until) || !rows[0].AttestedAt.Equal(at) {
		t.Fatalf("coverage round trip: %+v", rows)
	}
	// A delayed duplicate full-proof write preserves coverage for the same proof.
	if err := s.UpsertCodeAttestation(ctx, proof); err != nil {
		t.Fatal(err)
	}
	rows, _ = s.ListCodeAttestations(ctx)
	if rows[0].ContinuousCoverageUntil == nil || !rows[0].ContinuousCoverageUntil.Equal(until) {
		t.Fatal("duplicate proof erased coverage")
	}
	for _, change := range []func(*CodeAttestation){func(r *CodeAttestation) { r.APNsToken = "other" }, func(r *CodeAttestation) { r.NodePublicKey = "other" }, func(r *CodeAttestation) { r.BinaryHash = "other" }, func(r *CodeAttestation) { r.Version = "other" }, func(r *CodeAttestation) { r.AttestedAt = at.Add(time.Second) }} {
		stale := observation
		future := until.Add(time.Hour)
		stale.ContinuousCoverageUntil = &future
		change(&stale)
		if err := s.AdvanceCodeAttestationCoverage(ctx, []CodeAttestation{stale}); err != nil {
			t.Fatal(err)
		}
		rows, _ = s.ListCodeAttestations(ctx)
		if !rows[0].ContinuousCoverageUntil.Equal(until) {
			t.Fatal("mismatched proof advanced coverage")
		}
	}
	// A newer real proof resets old-process coverage; old asynchronous writes lose.
	newer := proof
	newer.AttestedAt = at.Add(time.Minute)
	newer.NodePublicKey = "new-process"
	if err := s.UpsertCodeAttestation(ctx, newer); err != nil {
		t.Fatal(err)
	}
	if err := s.UpsertCodeAttestation(ctx, observation); err != nil {
		t.Fatal(err)
	}
	if err := s.AdvanceCodeAttestationCoverage(ctx, []CodeAttestation{observation}); err != nil {
		t.Fatal(err)
	}
	rows, _ = s.ListCodeAttestations(ctx)
	if rows[0].NodePublicKey != newer.NodePublicKey || rows[0].ContinuousCoverageUntil != nil {
		t.Fatal("old process restored proof or coverage")
	}
	if err := s.DeleteCodeAttestation(ctx, proof.SEPubKey); err != nil {
		t.Fatal(err)
	}
	if err := s.AdvanceCodeAttestationCoverage(ctx, []CodeAttestation{observation}); err != nil {
		t.Fatal(err)
	}
	rows, _ = s.ListCodeAttestations(ctx)
	if len(rows) != 0 {
		t.Fatal("coverage resurrected deleted proof")
	}
}
func TestMemoryCodeCoverageContract(t *testing.T)   { codeCoverageContract(t, NewMemory(Config{})) }
func TestPostgresCodeCoverageContract(t *testing.T) { codeCoverageContract(t, testPostgresStore(t)) }
