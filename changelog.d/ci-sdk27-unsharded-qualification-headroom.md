### CI: the unsharded SDK 27 qualification gets 45 minutes

- The SDK 27 release preparation on a pull request runs the whole provider suite
  serially on one Mac. Its test deadline moves from 30 to 45 minutes, inside the
  job's 60-minute limit. The five release qualification shards keep 30 minutes.
