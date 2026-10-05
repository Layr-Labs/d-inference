// Package store defines persistence contracts, domain records, errors, and the
// read-through cache decorator. Backend construction belongs to the composition
// root: memory.NewMemory provides non-durable development storage, while
// postgres.NewPostgres provides durable transactional storage.
//
// Both implementations depend on this package; this package never imports a
// backend. As unwraps decorators when callers need an optional store capability.
// Monetary amounts are micro-USD (1 USD = 1,000,000 micro-USD).
package store
