package capacityvalue

// ClampMsInt32 narrows a millisecond count (int64) to int32, saturating.
func ClampMsInt32(ms int64) int32 {
	const maxI32 = int64(^uint32(0) >> 1)
	if ms > maxI32 {
		return int32(maxI32)
	}
	if ms < 0 {
		return 0
	}
	return int32(ms)
}
