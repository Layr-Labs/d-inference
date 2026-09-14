package memory

import (
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/releaseversion"
)

func releaseKey(version, platform string) string {
	return version + ":" + platform
}

func (s *Store) SetRelease(release *contracts.Release) error {
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

func (s *Store) ListReleases() []contracts.Release {
	s.mu.RLock()
	defer s.mu.RUnlock()
	releases := make([]contracts.Release, 0, len(s.releases))
	for _, r := range s.releases {
		releases = append(releases, *r)
	}
	sort.Slice(releases, func(i, j int) bool {
		return releases[i].CreatedAt.After(releases[j].CreatedAt)
	})
	return releases
}

func (s *Store) ListReleasesWithError() ([]contracts.Release, error) {
	return s.ListReleases(), nil
}

func (s *Store) GetLatestRelease(platform string) *contracts.Release {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var latest *contracts.Release
	for _, r := range s.releases {
		if r.Platform != platform || !r.Active {
			continue
		}
		if latest == nil ||
			releaseversion.Greater(r.Version, latest.Version) ||
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

func (s *Store) DeleteRelease(version, platform string) error {
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
