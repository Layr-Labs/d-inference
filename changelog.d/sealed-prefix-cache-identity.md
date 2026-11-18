### Prefix-cache identity read from the sealed request

- A coordinator can now send a request's prefix-cache scope and repeat demand inside the encrypted request body (`_darkbloom_cache`), bound to the dispatch attempt by its receipt nonce. The provider uses that copy in place of the frame's `cache_scope` and `cache_repeated_prefix_tokens`, and ignores a copy whose nonce is not the attempt's.
- Coordinators that send no copy are served as before, from the frame's fields.
