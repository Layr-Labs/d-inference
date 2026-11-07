### A pair's leader can take its owner's local requests beside Darkbloom

- The member that hosts a pair's slot can now run the local OpenAI-compatible API while the pair serves through Darkbloom. Local and Darkbloom requests share the pair's one engine and its lanes: no second process or engine, and no extra copy of the stream. No command starts it yet: `darkbloom start --cluster-member` still refuses `--local-endpoint`, and `darkbloom cluster` keeps serving a pair through Darkbloom with no local API.
- Only that member runs it, and always with a key. Any other member still refuses a local API.
- While the pair isn't serving (it is forming, re-forming or stopped), a local request gets 503, as `darkbloom cluster local` answers, instead of a 500. A model the pair doesn't serve gets 404.
- When every lane is busy, a local request waits its turn in a bounded queue, as on `darkbloom cluster local` (`DARKBLOOM_CLUSTER_QUEUE_WAITING`, default 64): 429 when the queue is full, 503 when it waited too long. A waiting request is woken when a lane frees and is never polled; Darkbloom requests never wait for it.
- A local request that arrives while the pair runs its first test request waits until the pair opens, and gets 503 if the pair stops instead.
