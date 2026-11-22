### GLM requests can wait for memory another model holds

When another model shares the Mac, a local GLM request that would fit with
GLM alone waits for its share of memory to grow. The provider checks the
actual grant again before starting it. If the wait expires, it returns
HTTP 503 with `Retry-After: 10`. A request that cannot fit even with GLM
alone still gets the immediate memory refusal.
