// Package warmpool owns demand, arrival, and occupancy measurements and computes
// warm-capacity targets from copied inputs. Its state has its own mutex; fleet
// snapshots, eligibility checks, and model-load commands stay in registry.
package warmpool
