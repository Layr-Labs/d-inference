### A two-Mac pair answers Darkbloom's checks and cancels while a long prompt is read

- A request that arrived while a pair was reading a long prompt could take up to 30 s to be admitted, because both Macs answer at the end of their current prompt step. Meanwhile the leading Mac held back the Darkbloom messages that came after it: attestation checks, cancels and the next requests. On one pair, a request waited 18 s before the leading Mac even read it, and a late answer to an attestation check counts against the pair.
- The leading Mac now answers attestation checks as they arrive, a cancel no longer holds back the messages behind it, and its reports of what the pair is serving keep updating.
- A cancelled request whose admission had not started yet is no longer admitted at all. One that is already being admitted is stopped as soon as that admission returns, and frees its place on the pair within one prompt step, as before.
- Unchanged: a request that arrives during a long prompt still waits for the pair to admit it, and for that prompt before its own is read, so a short request can still time out before its first token. Such a request is safe to retry.
