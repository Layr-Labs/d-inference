package response

import (
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func RequestTimingDetails(timing *registry.RequestTiming) *types.RequestTimingDetails {
	if timing == nil {
		return nil
	}
	tj := &types.RequestTimingDetails{}
	if !timing.ParsedAt.IsZero() {
		tj.ParseUs = timing.ParsedAt.Sub(timing.ReceivedAt).Microseconds()
	}
	if !timing.ReservedAt.IsZero() && !timing.ParsedAt.IsZero() {
		tj.ReserveUs = timing.ReservedAt.Sub(timing.ParsedAt).Microseconds()
	}
	routeAnchor := timing.ReservedAt
	if !timing.MediaFetchedAt.IsZero() && !timing.ReservedAt.IsZero() {
		tj.MediaFetchUs = timing.MediaFetchedAt.Sub(timing.ReservedAt).Microseconds()
		routeAnchor = timing.MediaFetchedAt
	}
	if !timing.RoutedAt.IsZero() && !routeAnchor.IsZero() {
		tj.RouteUs = timing.RoutedAt.Sub(routeAnchor).Microseconds()
	}
	if !timing.QueuedAt.IsZero() && !timing.DispatchedAt.IsZero() {
		tj.QueueUs = timing.DispatchedAt.Sub(timing.QueuedAt).Microseconds()
	}
	if !timing.EncryptedAt.IsZero() && !timing.RoutedAt.IsZero() {
		tj.EncryptUs = timing.EncryptedAt.Sub(timing.RoutedAt).Microseconds()
	}
	if !timing.DispatchedAt.IsZero() && !timing.EncryptedAt.IsZero() {
		tj.DispatchUs = timing.DispatchedAt.Sub(timing.EncryptedAt).Microseconds()
	}
	if !timing.FirstChunkAt.IsZero() && !timing.DispatchedAt.IsZero() {
		tj.ProviderUs = timing.FirstChunkAt.Sub(timing.DispatchedAt).Microseconds()
	}
	return tj
}
