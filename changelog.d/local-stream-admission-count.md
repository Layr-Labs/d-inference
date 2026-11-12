### Small local requests sent together are no longer refused as "memory" on a warm Mac

- While a Mac's heat or Low Power Mode holds a model to its fallback width (4 instead of the M5's 8, as often right after a start on a warm Mac), a streamed local-API request waiting for its first token counted twice. So the third or fourth of four small requests sent together got 503 "This Mac's memory can't hold this request right now" with most memory free. Each request now counts once, as the memory check already did; a fifth is still refused.
