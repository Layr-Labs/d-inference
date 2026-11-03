### App Attest restart covers the first episode after an update

- The `is_supported_false` restart now also works in the first process after an update from a version that did not record its App Attest authorizations. At start, when `app-attest-verified.json` is missing, the provider fills it once from the previous `daemon-state.json`: the time of an App Attest grant, or the last successful Apple call of a stored key that Apple attested. All other conditions stay the same.
