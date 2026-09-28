# Transparent model-shard reconstruction spike

> Last updated: 2026-09-27 · commit `93d556533`

This local-only spike tests whether an existing large model-shard URL can be
served byte-for-byte from smaller backing objects without changing the client,
model manifest, safetensors index, final file, or aggregate hash.

It deliberately contains no Cloudflare account identifiers, credentials,
bindings, routes, deployment configuration, or production object writes.

Run it with the Node.js built-in test runner:

```sh
node --test docs/spikes/transparent-reconstruction-poc/reconstructor.test.mjs
```

The optional local Workers-runtime check uses `FixedLengthStream` so workerd,
not Node, determines the actual HTTP framing and `Content-Length` behavior:

```sh
cd docs/spikes/transparent-reconstruction-poc
npm install
npm run dev
```

This Wrangler configuration has no routes, account identifiers, remote
bindings, or deployment script. The documented command always uses `--local`.
The `X-Test-Fail-At` header and `failAt` query parameter exist only in the local
fixture Worker to force a connection failure and validate byte-range resume
through workerd.

The compatibility contract covered by the tests is:

- Full `GET` returns the exact original bytes and identity headers.
- `HEAD` returns the original size without retrieving backing chunks.
- A single standard, open-ended, or suffix byte range returns exact `206`
  bytes and a valid `Content-Range`.
- Unsatisfiable or unsupported multi-range requests return `416` and
  `Content-Range: bytes */<original-size>`.
- A failure after some chunk bytes have streamed can resume from the exact
  durable prefix using `Range: bytes=N-`.
- Cancellation aborts pending chunk fetches and releases active or late response
  bodies; invalid upstream responses are cancelled before rejection.
- Chunk manifests must cover the logical object contiguously with no gaps or
  overlaps.

The implementation is written against standard `Request`, `Response`, Headers,
and `ReadableStream` APIs so the reconstruction logic can be adapted to a
Cloudflare Worker, while remaining runnable without Cloudflare access.


This spike is separate from the [recorded storage benchmark](../model-download-benchmark/README.md),
which downloaded parts as independent manifest files and concatenated them in an
external verifier. Neither experiment establishes production delivery performance.
