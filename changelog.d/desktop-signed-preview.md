### Desktop signed preview build

- Add an opt-in, Developer ID signed Darkbloom Preview DMG with a bundled desktop API, separate application state, and managed API startup and shutdown. Provider operations stay on the verified installed runtime; normal release signing requirements are unchanged.
- Recover after a crash or force quit by stopping the leftover bundled API (verified by recorded pid and exact command) before starting a new one, and report the installed runtime's version rather than the bundled API's build version.
