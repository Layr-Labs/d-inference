// Package store is the compatibility facade for coordinator persistence.
// It aliases the contracts and forwards constructors; it owns no backend state.
//
// The contracts package defines records and domain interfaces. The memory and
// postgres packages own their respective synchronization and transaction
// boundaries. The cache package decorates a contract and exposes its underlying
// backend through Unwrap so As can discover optional capabilities.
package store
