### Clusters need no waitlist

- `darkbloom cluster` no longer asks the coordinator for a `cluster` waitlist approval before a new pair: Darkbloom dropped the clusters waitlist on 2026-11-23, and any account may set up a cluster. Earlier releases read the coordinator's `404` and go on after one line; this one asks nothing.
- `darkbloom waitlist` and `darkbloom cluster` help no longer name a clusters waitlist. Darkbloom Sandbox's waitlist and `darkbloom sandbox setup`'s approval are unchanged.
