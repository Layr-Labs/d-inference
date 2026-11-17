### Release publication retries a stalled artifact download

- Release publication (CI only; no provider change): the staging and publish jobs download the signed publication artifact with up to 3 attempts of 420 s each instead of one of 300 s, and each job has 35 minutes. A stalled attempt starts over; the artifact's digest is still checked before anything is staged or registered.
