### CI: release SDK qualification runs on Darkbloom; releases pin their inputs and use no cache

- The five "Qualify provider with SDK 27" shards and their gate moved into `release-qualify.yml`. Each release caller calls it from one job, `qualify`, with read-only permissions and no secrets, before its credentialed release call. The shards ask the Darkbloom plane on lane `release-qualify` (count 5, size 12x32, not in tag runs) and keep `blacksmith-12vcpu-macos-27` when the plane does not grant it.
- The older-macOS smoke now takes the signed validation bundle by `build-and-release`'s artifact ID, as signing, staging and publication already did, and checks the zip's SHA-256 against its digest before it reads it, never by name.
- No release job restores or saves an Actions cache, since any job of the branch, a routed one too, can write any cache key. Release builds and qualification compile cold.
- A release now builds after qualification and without caches: expect roughly 45 to 60 minutes instead of about 17.
