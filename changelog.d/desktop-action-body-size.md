### Desktop app refuses an action larger than the runtime reads

- The desktop app now refuses an action whose request body would exceed the
  16 KiB the local runtime reads, before posting it. It stops serializing the
  action as soon as the body must be larger, so an oversized action is never
  copied whole into a request. Actions the app sends are far smaller and are
  posted as before.
