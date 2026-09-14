package api

import (
	"github.com/eigeninference/d-inference/coordinator/api/accountfleet"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
)

func (s *Server) newAccountFleet() *accountfleet.Controller {
	return accountfleet.New(accountfleet.Dependencies{
		Store:         func() accountfleet.Store { return s.store },
		Registry:      func() accountfleet.Registry { return s.registry },
		Cache:         func() *readcache.Cache { return s.readCache },
		MinVersion:    func() string { return s.minProviderVersion },
		LatestVersion: s.latestReleasedVersion,
		RequireUser:   s.requirePrivyUser,
		VersionLess:   semverLess,
		Logger:        s.logger,
	})
}
