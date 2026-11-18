### Provider releases check every signed executable for get-task-allow

- After signing, the release lane now reads the entitlements of every executable in `Darkbloom.app` (the CLI, the Secure Enclave helper, the fan helper, the cluster worker and the cluster plan) and stops the release if any of them is unsigned or carries `get-task-allow`. Until now only the CLI was checked. `scripts/provider-signing-validation.py bundle-entitlements --app <app>` runs the check.
