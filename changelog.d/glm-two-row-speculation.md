### GLM-5.3-Flash speculates for two concurrent requests

GLM's embedded MTP now verifies the draft windows of two decoding requests in one target forward, instead of
turning speculation off as soon as a second request decodes. On an M5 Ultra, two concurrent requests decode at
about 47 tok/s each instead of 38 (aggregate 92-95 instead of 76 tok/s). One request, and three or more, decode as
before.
