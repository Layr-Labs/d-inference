package store

import "context"

// AppAttestReadinessBatchStore supports bounded refreshes of live credential
// state. Each call is one snapshot; an omitted key is unknown, not unrevoked.
// Serving callers must bound the snapshot's lifetime and fence local revocations
// immediately rather than treating successful reads as permanent authorization.
type AppAttestReadinessBatchStore interface {
	GetAppAttestReadinessBatch(context.Context, []string) (map[string]AppAttestReadiness, error)
}

const AppAttestReadinessBatchLimit = 1000
