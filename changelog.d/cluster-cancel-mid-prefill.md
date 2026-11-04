### A client that disconnects during a long prompt no longer stalls a two-Mac pair

- On a pair that serves several requests at once, a request whose client disconnects before any output now stops within seconds instead of first running its whole prompt, and the pair serves the next request at once. Before, a 60,000-token prompt kept both Macs busy for about 4 minutes, and the requests that arrived meanwhile failed. A pair that serves one request at a time still runs the prompt to its end.
