### CI: release SDK qualification runs on Darkbloom; releases pin their inputs and use no cache

- The five "Qualify provider with SDK 27" shards and their gate moved into `release-qualify.yml`. Each release caller calls it from one job, `qualify`, with read-only permissions and no secrets, before its credentialed release call. The shards ask the Darkbloom plane on lane `release-qualify` (count 5, not in tag runs) and keep `blacksmith-12vcpu-macos-27` when the plane does not grant it.
- Signing and the older-macOS smoke now take their input by the producing Blacksmith job's artifact ID, as staging and publication already did. They check the zip's SHA-256 against its digest before they read it, never by name. `provider-signing-validation.yml` does the same.
- No release job restores or saves an Actions cache, since any job of the branch, a routed one too, can write any cache key. Release builds and qualification compile cold, and the desktop release uses no npm cache.
- A release now builds after qualification and without caches: expect roughly 45 to 60 minutes instead of about 17.
