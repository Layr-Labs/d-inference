package store

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
)

func testBuildQualification() AppAttestBuildQualification {
	return AppAttestBuildQualification{AppAttestBuildIdentity: AppAttestBuildIdentity{
		Release: Release{Version: "90.0.1", Platform: "macos-arm64", Backend: "mlx-swift",
			BinaryHash: strings.Repeat("a", 64), BundleHash: strings.Repeat("b", 64), MetallibHash: strings.Repeat("c", 64), URL: "https://releases.example/bundle"},
		CodeDirectoryHash: strings.Repeat("d", 64), SourceCommit: strings.Repeat("e", 40), CIRunID: "1234"},
		Evidence: "physical SIP/Full Security transitions and signed runtime smoke: evidence/run-1234", ApprovedBy: "operator"}
}

func buildQualificationContract(t *testing.T, backend Store) {
	t.Helper()
	s, ok := As[AppAttestBuildStore](backend)
	if !ok {
		t.Fatal("qualification capability missing through decorator")
	}
	ctx := context.Background()
	q := testBuildQualification()
	if err := s.SetQualifiedRelease(ctx, q.AppAttestBuildIdentity); !errors.Is(err, ErrBuildNotQualified) {
		t.Fatalf("unapproved release: %v", err)
	}
	if backend.GetLatestRelease(q.Release.Platform) != nil {
		t.Fatal("unqualified build became latest")
	}
	if changed, err := s.QualifyAppAttestBuild(ctx, q); err != nil || !changed {
		t.Fatalf("approve: %v %v", changed, err)
	}
	if changed, err := s.QualifyAppAttestBuild(ctx, q); err != nil || changed {
		t.Fatalf("idempotent approve: %v %v", changed, err)
	}
	rows, err := s.ListAppAttestBuildQualifications(ctx)
	if err != nil || len(rows) != 1 || rows[0].ApprovedAt.IsZero() || rows[0].ApprovedBy != "operator" {
		t.Fatalf("audit: %+v %v", rows, err)
	}
	for _, mutate := range []func(*AppAttestBuildIdentity){
		func(b *AppAttestBuildIdentity) { b.CodeDirectoryHash = strings.Repeat("f", 64) },
		func(b *AppAttestBuildIdentity) { b.Release.BundleHash = strings.Repeat("f", 64) },
		func(b *AppAttestBuildIdentity) { b.Release.MetallibHash = strings.Repeat("f", 64) },
		func(b *AppAttestBuildIdentity) { b.Release.Version = "90.0.2" },
		func(b *AppAttestBuildIdentity) { b.SourceCommit = strings.Repeat("f", 40) },
		func(b *AppAttestBuildIdentity) { b.CIRunID = "5678" },
		func(b *AppAttestBuildIdentity) { b.Release.URL += "/different" },
	} {
		other := q
		mutate(&other.AppAttestBuildIdentity)
		if _, err := s.QualifyAppAttestBuild(ctx, other); !errors.Is(err, ErrBuildConflict) {
			t.Fatalf("changed approval accepted: %v", err)
		}
		if err := s.SetQualifiedRelease(ctx, other.AppAttestBuildIdentity); !errors.Is(err, ErrBuildNotQualified) {
			t.Fatalf("mismatched publication: %v", err)
		}
	}
	for range 2 {
		if err := s.SetQualifiedRelease(ctx, q.AppAttestBuildIdentity); err != nil {
			t.Fatal(err)
		}
	}
	if latest := backend.GetLatestRelease(q.Release.Platform); latest == nil || latest.BinaryHash != q.Release.BinaryHash {
		t.Fatal("approved release not discoverable")
	}
	// Concurrent publication and revocation serialize; after revoke returns,
	// no new publication can pass, including on a newly constructed store.
	var wg sync.WaitGroup
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			err := s.SetQualifiedRelease(ctx, q.AppAttestBuildIdentity)
			if err != nil && !errors.Is(err, ErrBuildNotQualified) {
				t.Error(err)
			}
		}()
	}
	if changed, err := s.RevokeAppAttestBuild(ctx, q.Release.BinaryHash, "security-operator", "withdrawn after qualification"); err != nil || !changed {
		t.Fatalf("revoke: %v %v", changed, err)
	}
	wg.Wait()
	if err := s.SetQualifiedRelease(ctx, q.AppAttestBuildIdentity); !errors.Is(err, ErrBuildNotQualified) {
		t.Fatalf("revoked publish: %v", err)
	}
	if _, err := s.QualifyAppAttestBuild(ctx, q); !errors.Is(err, ErrBuildConflict) {
		t.Fatalf("revoked approval resurrected: %v", err)
	}
	if changed, err := s.RevokeAppAttestBuild(ctx, q.Release.BinaryHash, "different-actor", "retry"); err != nil || changed {
		t.Fatalf("revoke retry: %v %v", changed, err)
	}
	rows, _ = s.ListAppAttestBuildQualifications(ctx)
	if rows[0].Evidence != q.Evidence || rows[0].RevokedBy != "security-operator" || rows[0].ApprovedBy != "operator" {
		t.Fatal("audit history overwritten")
	}
	// A previously env-only build can be fenced with a durable tombstone.
	if _, err := s.RevokeAppAttestBuild(ctx, strings.Repeat("f", 64), "operator", "legacy withdrawal"); err != nil {
		t.Fatal(err)
	}
}

func TestBuildQualificationsMemory(t *testing.T) { buildQualificationContract(t, NewMemory(Config{})) }

func TestBuildQualificationsPostgres(t *testing.T) {
	s := testPostgresStore(t)
	// This harness intentionally leaves release rows for other contracts. Use a
	// test-owned clean release inventory for atomic-publication assertions.
	if _, err := s.pool.Exec(context.Background(), "TRUNCATE releases"); err != nil {
		t.Fatal(err)
	}
	buildQualificationContract(t, s)
	fresh := &PostgresStore{pool: s.pool}
	rows, err := fresh.ListAppAttestBuildQualifications(context.Background())
	if err != nil || len(rows) != 2 {
		t.Fatalf("restart lost policy: %+v %v", rows, err)
	}
	if err := fresh.SetQualifiedRelease(context.Background(), testBuildQualification().AppAttestBuildIdentity); !errors.Is(err, ErrBuildNotQualified) {
		t.Fatalf("restart lost revocation: %v", err)
	}
}

func TestBuildQualificationCannotReplacePublishedVersion(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			s, _ := As[AppAttestBuildStore](backend)
			q := testBuildQualification()
			q.Release.Version = "91.0.1"
			old := q.Release
			old.BinaryHash = strings.Repeat("f", 64)
			if err := backend.SetRelease(&old); err != nil {
				t.Fatal(err)
			}
			if _, err := s.QualifyAppAttestBuild(context.Background(), q); err != nil {
				t.Fatal(err)
			}
			if err := s.SetQualifiedRelease(context.Background(), q.AppAttestBuildIdentity); !errors.Is(err, ErrBuildConflict) {
				t.Fatalf("replaced published bytes: %v", err)
			}
		})
	}
}

func TestBuildQualificationsCachedStore(t *testing.T) {
	buildQualificationContract(t, NewCached(NewMemory(Config{}), CacheConfig{}))
}
