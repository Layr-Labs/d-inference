package capacityvalue

// Broad physical/cumulative limits bound untrusted observations without
// affecting admission. Missing instrumentation remains distinct from zero.
const MaxCapacitySampleValue = uint64(1 << 60)

const MaxCapacitySampleGaugeBytes = uint64(1 << 50)
