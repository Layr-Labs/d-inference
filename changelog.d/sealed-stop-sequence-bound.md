### Sealed stop sequence bound

- The sealed usage carries the matched stop sequence only when it is at most
  4096 UTF-8 bytes; a longer one is left out whole, and the finish reason
  still says `stop`. Requests may still carry longer stop strings.
