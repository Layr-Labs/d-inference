package modelloads

import "time"

// PendingTTL bounds how long an outstanding (or failed) load_model
// suppresses re-sends to the same provider.
const PendingTTL = 2 * time.Minute

// DrainBackoff is the short cooldown used when a provider
// rejects load_model because it is draining for an auto-update restart. The
// entry keeps the planner away from a provider that is about to bounce, but
// must not outlive a failed restart: if the provider aborts the restart and
// resumes serving, it is fully loadable again, and the full 2-minute cooldown
// would strand queued requests that this provider (or its post-restart
// re-registration) could serve.
const DrainBackoff = 30 * time.Second

// MemoryBackoff is the short cooldown used when a proactive
// load_model fails for a NON-draining reason — dominated by transient memory
// pressure (insufficient free memory / KV headroom) that frees within seconds
// as in-flight requests on other slots finish. Leaving the full
// PendingTTL (2 min, ≈ the 120s request-queue timeout) would suppress
// proactive re-loads to this provider long enough that a request which queues
// right after the failure times out before the provider is reconsidered, even
// though its memory may have freed almost immediately. Kept equal to the drain
// backoff today but named separately so the two can diverge. The ~10s warm-pool
// sweep reaps the re-stamped entry deterministically.
const MemoryBackoff = 30 * time.Second

// PlanInterval is the minimum spacing between heartbeat-triggered
// swap plans, fleet-wide. 250 ms keeps a newly-queued cold model's load_model
// within a quarter second of the next heartbeat (heartbeats arrive every ~4
// ms at fleet scale) while bounding planner CPU to ≤ 4 plans/s regardless of
// fleet size or queue depth. The explicit TriggerModelSwaps entry point
// (api cold-dispatch kick, tests) stays immediate and is not subject to this
// gate. Deliberately a constant, not an env knob.
const PlanInterval = 250 * time.Millisecond
