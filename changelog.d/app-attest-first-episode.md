### App Attest restart covers the first episode after an update

- The `is_supported_false` restart now also works in the first process after an update from a version that did not record its App Attest authorizations. At serve start, when `app-attest-verified.json` is missing, the provider fills it once from the previous `daemon-state.json`, with evidence from the last 7 days: the last successful Apple call of a stored key that Apple attested, or an App Attest grant left by an unclean exit. All other conditions stay the same.
- A Mac whose previous provider was itself reporting `is_supported_false` has no such evidence, so it still waits for the coordinator to grant App Attest again.
