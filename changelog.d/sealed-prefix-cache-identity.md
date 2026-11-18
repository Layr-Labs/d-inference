### The provider can read a request's prefix-cache identity from its encrypted body (not used yet)

- The provider reads a `_darkbloom_cache` member of the encrypted request body and uses its prefix-cache scope and repeat demand only when its nonce is the attempt's `cache_receipt_nonce`; otherwise, and without the member, it uses the frame's fields exactly as before.
