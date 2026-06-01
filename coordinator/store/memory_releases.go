package store

import (
	"errors"
	"fmt"
	"sort"
	"time"
)

// --- Releases ---

func releaseKey(version, platform string) string {
	return version + ":" + platform
}

func (s *MemoryStore) SetRelease(release *Release) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if release.Version == "" || release.Platform == "" {
		return errors.New("version and platform are required")
	}
	r := *release
	if r.CreatedAt.IsZero() {
		r.CreatedAt = time.Now()
	}
	r.Active = true
	s.releases[releaseKey(r.Version, r.Platform)] = &r
	return nil
}

func (s *MemoryStore) ListReleases() []Release {
	s.mu.RLock()
	defer s.mu.RUnlock()
	releases := make([]Release, 0, len(s.releases))
	for _, r := range s.releases {
		releases = append(releases, *r)
	}
	sort.Slice(releases, func(i, j int) bool {
		return releases[i].CreatedAt.After(releases[j].CreatedAt)
	})
	return releases
}

func (s *MemoryStore) GetLatestRelease(platform string) *Release {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var latest *Release
	for _, r := range s.releases {
		if r.Platform != platform || !r.Active {
			continue
		}
		if latest == nil ||
			releaseVersionGreater(r.Version, latest.Version) ||
			(r.Version == latest.Version && r.CreatedAt.After(latest.CreatedAt)) {
			latest = r
		}
	}
	if latest == nil {
		return nil
	}
	copy := *latest
	return &copy
}

func (s *MemoryStore) DeleteRelease(version, platform string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := releaseKey(version, platform)
	r, ok := s.releases[key]
	if !ok {
		return fmt.Errorf("release %s/%s not found", version, platform)
	}
	r.Active = false
	return nil
}
