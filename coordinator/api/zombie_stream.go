package api

// Zombie-stream cancel tracking.
//
// Every abandon path that may leave a provider generating records its request
// here before it sends the cancel (sendAbandonCancel / cancelDispatch) and
// marks the entry sent only once the frame was handed to the provider writer.
// The entry lets the coordinator:
//
//   - correlate the provider's eventual terminal with the cancel and emit
//     inference.cancel_to_terminal_ms instead of dropping it as "unknown";
//   - re-send the cancel on an escalating schedule while stray chunks prove the
//     provider has not stopped, so a cancel lost to a full control lane or
//     delayed behind a cold model load is retried within ~1 s, not 10 s;
//   - attribute every cancel to a bounded cause.
//
// The map is bounded (zombieCancelMaxEntries) and swept opportunistically by
// the calls that touch it — there is no background goroutine, so a
// terminal-less entry is reported when the map is next used, not exactly at
// expiry.
