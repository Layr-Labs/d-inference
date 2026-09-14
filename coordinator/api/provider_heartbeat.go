package api

// Older snapshots remain visible with age but emit no current-value samples.
// This shared telemetry limit is observational, never a routing gate.
const capacitySampleFreshMS = 5 * 60 * 1000
