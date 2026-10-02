package api

import (
	"net/http"
	"time"
)

type desktopRelease struct {
	Version     string    `json:"version"`
	PublishedAt time.Time `json:"published_at"`
	Notes       string    `json:"notes"`
	Active      bool      `json:"active"`
}

type desktopReleaseFeed struct {
	MinimumProviderVersion string           `json:"minimum_provider_version"`
	History                []desktopRelease `json:"history"`
	ObservedAt             time.Time        `json:"observed_at"`
}

// handleDesktopReleases publishes release notes and the current version floor.
// It carries no artifact URLs, identities, or policy overrides. Download and
// authorization decisions still go through the existing native updater.
func (s *Server) handleDesktopReleases(w http.ResponseWriter, r *http.Request) {
	const key = "desktop-release-history"
	var history []desktopRelease
	if cached, ok := s.readCacheGetValue(key); ok {
		history, _ = cached.([]desktopRelease)
	}
	if history == nil {
		releases, err := s.store.ListReleasesWithError()
		if err != nil {
			writeJSON(w, http.StatusServiceUnavailable, errorResponse("unavailable", "Release history is unavailable"))
			return
		}
		history = make([]desktopRelease, 0)
		for _, release := range releases {
			if release.Platform != defaultReleasePlatform {
				continue
			}
			history = append(history, desktopRelease{Version: release.Version, PublishedAt: release.CreatedAt, Notes: release.Changelog, Active: release.Active})
			if len(history) == 30 {
				break
			}
		}
		if s.readCache != nil {
			s.readCache.SetValue(key, history, 30*time.Second)
		}
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, desktopReleaseFeed{
		MinimumProviderVersion: s.minProviderVersion, History: history, ObservedAt: time.Now().UTC(),
	})
}
