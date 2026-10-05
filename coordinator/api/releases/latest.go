package releases

// LatestReleasedVersion returns the highest active release version from
// the store, falling back to the hardcoded s.hooks.LatestProviderVersion() when
// no release record exists.
func (s *Owner) LatestReleasedVersion() string {
	if release := s.store.GetLatestRelease(defaultReleasePlatform); release != nil {
		return release.Version
	}
	return s.hooks.LatestProviderVersion()
}
