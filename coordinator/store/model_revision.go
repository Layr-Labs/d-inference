package store

import "errors"

// ErrModelVersionImmutable prevents a published version from changing underneath
// downloads, loaded engines, attestation, or rollback. Publish a new version.
var ErrModelVersionImmutable = errors.New("model version is immutable; publish a new version")

// ErrModelVersionRetired prevents retries from reviving a revoked artifact.
var ErrModelVersionRetired = errors.New("model revision is retired; publish a new version")

// ErrActiveModelVersion requires selecting a replacement before revocation.
var ErrActiveModelVersion = errors.New("cannot retire the active model revision; promote a replacement first")
