package qualification

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const Freshness = 30 * time.Second

// Bootstrap is the deployment's immutable compatibility allowlist. Durable
// rows, including revocation tombstones, always take precedence.
type Bootstrap struct {
	BuildHashes string
	CodeHashes  string
}

type Catalog struct {
	Known                    bool
	ContainsQualifiedRelease func(store.Release) bool
}

type snapshot struct {
	generation uint64
	observedAt time.Time
	builds     map[string]store.AppAttestBuildQualification
}

// Cache serializes reads and local revocation fences. The zero value is empty
// and denies qualification until a successful refresh.
type Cache struct {
	mu      sync.Mutex
	current atomic.Pointer[snapshot]
}

func (c *Cache) Refresh(ctx context.Context, st store.AppAttestBuildStore, fence func(uint64)) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if st == nil {
		return errors.New("build qualification storage unavailable")
	}
	observed := time.Now().UTC()
	rows, err := st.ListAppAttestBuildQualifications(ctx)
	if err != nil {
		return err
	}
	builds := make(map[string]store.AppAttestBuildQualification, len(rows))
	for _, q := range rows {
		builds[q.Release.BinaryHash] = q
	}
	c.publish(builds, observed, fence)
	return nil
}

// The registry fence precedes publication, so a verifier cannot reinstall an
// old lease while a new qualification generation is becoming visible.
func (c *Cache) publish(builds map[string]store.AppAttestBuildQualification, observed time.Time, fence func(uint64)) {
	old := c.current.Load()
	generation := uint64(1)
	if old != nil {
		generation = old.generation
		if !reflect.DeepEqual(old.builds, builds) {
			generation++
		}
	}
	if fence != nil {
		fence(generation)
	}
	c.current.Store(&snapshot{generation: generation, observedAt: observed, builds: builds})
}

// FenceBuild preserves the age of every other build's cached evidence.
func (c *Cache) FenceBuild(binary string, fence func(uint64)) {
	c.mu.Lock()
	defer c.mu.Unlock()
	builds := map[string]store.AppAttestBuildQualification{}
	observed := time.Time{}
	if old := c.current.Load(); old != nil {
		observed = old.observedAt
		for hash, q := range old.builds {
			builds[hash] = q
		}
	}
	q := builds[binary]
	q.Release.BinaryHash, q.RevokedAt = binary, time.Now().UTC()
	builds[binary] = q
	c.publish(builds, observed, fence)
}

// Apply rechecks the authenticated measurement on every lease refresh. Cached
// match booleans never substitute for evidence from the current generation.
func (c *Cache) Apply(e *appattest.AuthorizationEvidence, status *protocol.AppAttestStatus, catalog *Catalog, bootstrap Bootstrap) (uint64, time.Time) {
	e.BuildQualified, e.CodeMeasurementKnown, e.CodeMeasurementMatched, e.CodeMeasurementAmbiguous = false, false, false, false
	snapshot := c.current.Load()
	if snapshot == nil || status == nil {
		return 0, time.Time{}
	}
	until := snapshot.observedAt.Add(Freshness)
	if !until.After(time.Now()) {
		return snapshot.generation, until
	}
	if q, exists := snapshot.builds[status.BinaryHash]; exists {
		if q.RevokedAt.IsZero() && q.AppAttestBuildIdentity.Validate() == nil &&
			q.Release.Version == status.AppVersion && q.Release.Platform == "macos-arm64" {
			e.BuildQualified = catalog != nil && catalog.Known && catalog.ContainsQualifiedRelease != nil && catalog.ContainsQualifiedRelease(q.Release)
			if e.CodeMeasurementTruncated {
				approved := !q.ApprovedAt.IsZero() && strings.TrimSpace(q.ApprovedBy) != "" && strings.TrimSpace(q.Evidence) != ""
				e.CodeMeasurementKnown = approved && SHA256PrefixHex(e.CodeDirectoryHash)
				// Cryptographic prefix binding is independent of catalog
				// availability; an outage must not become a hard code mismatch.
				if e.CodeMeasurementKnown {
					e.CodeMeasurementMatched, e.CodeMeasurementAmbiguous = UniqueCodePrefix(snapshot.builds, status.BinaryHash, q.CodeDirectoryHash, e.CodeDirectoryHash)
				}
				e.BuildQualified = e.BuildQualified && approved
			} else {
				e.CodeMeasurementKnown = SHA256Hex(e.CodeDirectoryHash)
				e.CodeMeasurementMatched = e.CodeMeasurementKnown && e.CodeDirectoryHash == q.CodeDirectoryHash
			}
		}
	} else if !e.CodeMeasurementTruncated {
		e.BuildQualified = Build(bootstrap.BuildHashes, status.BinaryHash)
		e.CodeMeasurementKnown, e.CodeMeasurementMatched = Code(bootstrap.CodeHashes, status.BinaryHash, e.CodeDirectoryHash)
	}
	return snapshot.generation, until
}

// UniqueCodePrefix considers all durable rows, including revoked builds. A
// self-reported binary cannot choose one of several colliding full digests.
func UniqueCodePrefix(builds map[string]store.AppAttestBuildQualification, binaryHash, fullHash, prefix string) (matched, ambiguous bool) {
	if !SHA256Hex(fullHash) || !SHA256PrefixHex(prefix) {
		return false, false
	}
	matches := 0
	selected := false
	for hash, q := range builds {
		if !SHA256Hex(q.CodeDirectoryHash) || !strings.HasPrefix(q.CodeDirectoryHash, prefix) {
			continue
		}
		matches++
		if hash == binaryHash && q.CodeDirectoryHash == fullHash {
			selected = true
		}
	}
	return selected && matches == 1, matches > 1
}

func (c *Cache) BuildReady(b store.AppAttestBuildIdentity) bool {
	snapshot := c.current.Load()
	if snapshot == nil || !snapshot.observedAt.Add(Freshness).After(time.Now()) {
		return false
	}
	q, ok := snapshot.builds[b.Release.BinaryHash]
	return ok && q.RevokedAt.IsZero() && q.Matches(b) && q.AppAttestBuildIdentity.Validate() == nil
}

func (c *Cache) ReleaseReady(r store.Release, bootstrap Bootstrap) bool {
	snapshot := c.current.Load()
	if snapshot == nil || !snapshot.observedAt.Add(Freshness).After(time.Now()) {
		return false
	}
	if q, ok := snapshot.builds[r.BinaryHash]; ok {
		b := q.AppAttestBuildIdentity
		b.Release = r
		return q.RevokedAt.IsZero() && q.Matches(b) && b.Validate() == nil
	}
	if !Build(bootstrap.BuildHashes, r.BinaryHash) {
		return false
	}
	for _, pair := range strings.Split(bootstrap.CodeHashes, ",") {
		binary, code, ok := strings.Cut(strings.TrimSpace(pair), ":")
		if ok && binary == r.BinaryHash {
			_, matched := Code(bootstrap.CodeHashes, binary, code)
			return matched
		}
	}
	return false
}
