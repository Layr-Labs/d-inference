// Package admission owns memory and token-budget policy for immutable provider
// snapshots. Registry retains live provider state, snapshot capture and atomic
// reservations; this package neither acquires provider locks nor commits work.
package admission
