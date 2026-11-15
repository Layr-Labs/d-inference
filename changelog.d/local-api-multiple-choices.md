### Local API refuses n above 1

- The local chat routes (`/v1/chat/completions`, `/chat/completions` and each item of `/v1/chat/completions/batch`) answer `n` above 1 with HTTP 400 `n > 1 is not supported` (`param` `n`) before any engine work, as the coordinator answers it. They returned one choice whatever `n` asked. Nemotron Super's owner keeps its own `Invalid inference request.`
