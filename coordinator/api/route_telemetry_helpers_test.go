package api

import "github.com/eigeninference/d-inference/coordinator/store"

func routeRec(id string, attempt int, provider string) *store.InferenceRouteRecord {
	return &store.InferenceRouteRecord{RequestID: id, Attempt: attempt, ProviderID: provider, Outcome: "selected", Model: "m"}
}
