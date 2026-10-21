### Fan helper startup discovery

- Retry an unusable startup fan or GPU sensor inventory every 30 seconds while the helper is enabled and awake. Restore previous ownership before accepting recovered hardware and require a fresh provider lease before engaging fans; transiently invalid startup sensor readings no longer leave the helper permanently unsupported.
