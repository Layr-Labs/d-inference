### Nemotron 3.5 Super: a video request takes one of the owner's two media rows

- On an owner serving three or more requests, a request whose only media is one video now runs beside an image or
  another video, as two images already do. Frame decoding and the vision tower stay one request at a time on the
  owner's preparation lane; the answers then decode side by side. Each video's full memory charge is reserved before
  its frames decode and held until it settles, so a video that does not fit is still refused (503).
- Before, a video was exclusive with other media: a second image or video sent to the same Mac waited a few seconds at
  most and was otherwise refused with 429 until the first answer ended.
- `DARKBLOOM_NEMOTRON_SUPER_CONCURRENT_VIDEO=off` keeps a video exclusive with other media again. `DARKBLOOM_NEMOTRON_SUPER_CONCURRENT_IMAGES`
  set to an off word still keeps every media request alone. Both are forwarded to the service.
