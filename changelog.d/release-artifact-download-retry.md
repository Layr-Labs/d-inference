### Release publication retries a stalled artifact download

- Release publication (CI only; no provider change): the staging and publish jobs download the signed publication artifact with up to 2 attempts of 20 minutes each instead of one of 300 s (hosted runners have fetched it at about 1 MB/s), and each job has 50 minutes. A stalled attempt starts over; the artifact's digest is still checked before anything is staged or registered.
