### GLM requests can wait for memory another model holds

When another model shares the Mac, a local GLM request that would fit with
GLM alone waits for its share of memory to grow. The provider checks the
actual grant again before starting it. If the wait expires, it returns
HTTP 503 with `Retry-After: 10`. A request that cannot fit even with GLM
alone still gets the immediate memory refusal.

The busy 503 now reads "This Mac is at capacity. Retry when more memory is
available.", since another loaded model may hold the memory.
`DARKBLOOM_GLM_SHARED_GRANT_WAIT=0` restores 0.10.17's behaviour and busy
words; the LaunchAgent forwards it.
