### Inkling 2 Mini accepts up to 64 images per request

- A request to `thinkingmachines/Inkling-2-Mini` may carry up to 64 images
  (was 16, the default for models without their own cap). The per-image 100 MP
  and per-request 384 MP pixel caps still apply and bound its visual tokens;
  a 65th image is refused as oversized media (HTTP 400).
  `DARKBLOOM_MAX_IMAGES_PER_REQUEST` still sets one cap for every model.
