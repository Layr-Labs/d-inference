### A model whose queue stops moving stops taking requests

- Before, a model whose engine held a queued request, ran nothing and took no step for minutes still reported itself idle, so the coordinator kept routing requests to it. Each was accepted and timed out without a word.
- Now such a model reads `crashed` after 30 s, so the coordinator routes around it. After 120 s the provider recovers it as it recovers any stalled engine: it rebuilds an ordinary engine, and retires a native MiMo slot, recording "Native MiMo slot failed; confirmed retirement or process restart required" in `darkbloom status`.
