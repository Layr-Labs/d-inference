### A two-Mac pair keeps no prompt-cache key in a file

- The prompt-prefix cache of a two-Mac pair is encrypted with a key derived from the Mac's Secure Enclave-rooted key. When that key cannot be loaded, the pair now uses a key that lasts one session and is never written, so cached prefixes are rebuilt in the next session. It no longer creates or reads `prefix-ssd-v1.key`.
