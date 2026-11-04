### Two-Mac cluster: Serve locally only starts the faster local plan, and a closing link names the other Mac

- Choosing **Serve locally only** at the first setup's login check now starts the local plan: the model is planned again
  for serving locally before anything starts, so Qwen 3.8 27B in tensor parallel keeps the speculative assistant that
  only local serving uses (measured on one pair: 15.7 tok/s without it, 36–39 tok/s with it).
- When a part keeps ending because the link to the other Mac keeps closing, the ✗ says so and names the other Mac's side
  ("the other Mac's worker ended or the cable dropped") instead of blaming this Mac and calling the other "running, no
  error reported"; the ✗ title no longer begins with "starting; ".
- The DevNet app's cluster screens and `status` name its own command (`darkbloom-dev …`), not the production
  `darkbloom`.
