### Your own requests pause Darkbloom on your Mac

- With the local API beside Darkbloom (`darkbloom start --local-endpoint`), the Mac stops taking Darkbloom requests
  while one of your requests uses a model on it, and takes them again once none of your requests has run for 2 minutes
  (`[local] me_first_idle_minutes`, 1 to 120). Before, your requests and Darkbloom's shared the Mac.
- Listing models, health checks, `/metrics`, the tokenizer utilities and requests the Mac refuses (a model it doesn't
  serve, a load that doesn't fit, a drain) don't count.
- `[local] me_first = false` keeps the shared serving. `darkbloom start --local` never connects to Darkbloom, so it
  has nothing to pause.
