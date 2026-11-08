### A streamed local request that can't get this Mac's memory is a 503 before any header

- A streamed request to this Mac's API sends its response head once the engine admits it. One the engine queued for
  memory and then couldn't admit, because its 120 s admission lease ran out or a full paged pool outlasted its
  requeues, now gets HTTP 503 with "This Mac's memory can't hold this request right now. Lower max_tokens or shorten
  the prompt (or send less media), or retry when this Mac's other requests finish.", before any SSE header. Before,
  it got HTTP 200 and then "Response generation failed".
- A request that isn't streamed and outlasts the admission lease gets the same words (they were "Provider capacity is
  temporarily unavailable.").
- The prompt progress comments start when the engine admits the request, so a queued request says nothing until then.
- A pair's API and Darkbloom's requests are unchanged. A request admitted and later preempted, and never admitted
  again, still ends a streamed answer with an error event.
