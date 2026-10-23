### Nemotron Super inline video body bound

- Nemotron 3.5 Super now accepts media request bodies up to 40 MiB, enough for one part at the shared 25 MiB inline-media cap as base64 and every body the provider's transports deliver. The former 8 MiB bound refused linked videos larger than about 6 MB as invalid media once the coordinator inlined them, including OpenRouter's 6.9 MB readiness video.
- A Super media body above the bound now fails as `media_too_large` instead of `invalid_media`.
- Super's worst-case media charge for capacity quotes grows with the bound: 4.67 GiB for one image (was 3.62), 4.54 GiB for one video (was 3.49) and 25.6 GiB for sixteen images (was 24.5). On small KV grants the default prefix bank keeps that larger charge free and can be 512 MiB smaller.
