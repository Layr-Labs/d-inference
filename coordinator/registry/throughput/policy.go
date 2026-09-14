package throughput

// Policy evaluates throughput against model and chip tables. The caller owns
// synchronization if it changes a supplied table while evaluations run.
type Policy struct {
	Models        map[string]ModelDecodeClass
	ChipBandwidth map[string]float64
}

// DefaultPolicy returns the built-in tables without copying them. Treat the
// tables as read-only while they are shared with concurrent evaluations.
func DefaultPolicy() Policy {
	return Policy{Models: modelDecodeClasses, ChipBandwidth: chipBandwidthGBps}
}
