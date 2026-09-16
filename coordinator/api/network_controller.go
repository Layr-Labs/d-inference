package api

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/api/network"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
)

func (s *Server) newNetworkViews() *network.Controller {
	return network.New(network.Dependencies{
		Store:  func() network.Store { return s.store },
		Fleet:  func() network.Fleet { return s.registry },
		Cache:  func() *readcache.Cache { return s.readCache },
		Logger: s.logger, Incr: s.ddIncr,
	})
}

// StartCacheRefreshers starts the independent stats, geography and earnings
// refresh loops. The supplied context retains their existing shutdown policy.
func (s *Server) StartCacheRefreshers(ctx context.Context) { s.networkViews.StartRefreshers(ctx) }
