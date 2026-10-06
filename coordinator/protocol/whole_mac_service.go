package protocol

// WholeMacServiceReservation correlates one live provider service lease with
// its coordinator reservation. It contains no user or model identifiers.
type WholeMacServiceReservation struct {
	ID           string  `json:"id"`
	UsedFraction float64 `json:"used_fraction"`
}
