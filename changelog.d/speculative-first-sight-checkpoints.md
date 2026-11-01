### Speculative first-sight checkpoints

- Honor an optional coordinator admission, `cache_first_sight_tokens`, that lets a provider save a complete checkpoint of a prompt the coordinator has not yet seen repeated. Coordinators send it only with a narrowed cache scope; it is off unless the coordinator enables it.
- Such a checkpoint is written on its own background lane, so proven writes never queue behind it; it is limited to one TTL's share of the daily write cap (instantaneous and rolling-day), never evicts another entry, and does not delay its requester's response. Refusals settle `skipped_novel` as before.
- A first-sight donor's response never waits for its checkpoint write; the provider still holds the request's memory and capacity until the write settles. A seeded request is never admitted a first-sight write.
- A proven donation of a checkpoint already queued as speculative turns that job into a proven write instead of dropping it.
