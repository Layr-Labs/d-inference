// Package capacityvalue normalizes provider-reported capacity values and
// creates detached heartbeat snapshots. It owns no registry or provider state;
// callers retain responsibility for locking while accepting a snapshot.
package capacityvalue
