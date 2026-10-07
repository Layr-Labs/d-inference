package deviceverification

// ApplyLateMDA attaches a late Apple response only to the exact scheduler job
// that issued work for this UDID. Unowned and stale-generation callbacks are
// dropped without any fleet-wide fallback.
func (s *Verifier) ApplyLateMDA(
	udid, commandUUID string,
	certChain [][]byte,
) {
	if s == nil || s.verificationBackend.
		Scheduler ==
		nil ||
		udid == "" || commandUUID == "" || len(certChain) == 0 {
		return
	}
	s.verificationBackend.
		Scheduler.
		ApplyLateMDA(udid, commandUUID, certChain)
}
