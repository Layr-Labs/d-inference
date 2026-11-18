### Release builds serve only over an encrypted coordinator connection

- A release build now refuses to serve through a coordinator URL that would connect without TLS (for example `ws://` or `http://`) and says how to fix it. `wss://` and `https://` coordinator URLs, including the default, keep working.
