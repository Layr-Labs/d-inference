### Nemotron 3.5 Super on an M5 speculates only while few requests decode

On an M5 the managed Super slot now drafts at depth 3 for one decoding request, 2 for two, 1 for three or four,
and decodes target-only from five (`3,2,1,1,0`; other Macs keep `3,2,2,2,1`). On an M5 Ultra speculation is
20–24% faster alone and ties at two requests, but at four requests depth 2 cost 7–9% and at eight depth 1 cost
13–15% of aggregate throughput against target-only decoding. `DARKBLOOM_NEMOTRON_SUPER_MTP_DEPTH` lists may
now contain `0` (target-only at that width) and still override the default.
