### A MiMo slot whose engine stops stepping stops taking requests

- Before, a native MiMo slot whose engine had stopped stepping, with a request queued and nothing running, still reported itself idle for as long as it stayed that way, so the coordinator kept routing requests to it. Each was accepted and timed out without a word.
- Now an engine whose native work failed and was sealed by the SDK reads `crashed` at once, on any model. A native MiMo slot whose queue holds work with nothing running and no step reads `crashed` after 30 s. Either way the coordinator routes around it, and the provider then retires the MiMo slot, recording "Native MiMo slot failed; confirmed retirement or process restart required" in `darkbloom status`.
- Other models keep their existing wedge rules: on them a queue that waits with nothing running is usually healthy.
