### Stopping no longer waits for requests the coordinator abandoned

- Before, `darkbloom stop`, `restart` and `update` waited for every accepted request to finish, including requests the coordinator had already cancelled because their client left or their first token was late. A request stuck behind a stalled engine never finished, so the drain timed out after its full deadline and asked for `--force`.
- Now a request the coordinator cancelled counts for at most 30 s after the cancel. Its answer has nobody to go to; if its task has not ended by then, the drain stops waiting for it. Memory and eviction still treat it as in flight until it ends, and a native MiMo slot still retires only after its last request.
