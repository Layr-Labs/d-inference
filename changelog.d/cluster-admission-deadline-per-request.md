### A pair no longer drops all its requests when one request runs out of time before it starts

- A two-Mac pair no longer drops all its requests when one request runs out of
  time before it starts. When a request arrived with almost none of its
  first-response time left and a busy Mac answered its reservation at its next
  step, the leader ended the whole pair: every request in flight failed
  (`distributed peer readiness lost`), the other Mac logged `session fenced:
  leader fenced: the request was cancelled before it started` (or `command
  refused`), and the pair re-formed about 20 seconds later. A GLM-5.3-Flash
  pair under load dropped six times in 19 minutes.
- Now only that request fails, with a deadline error. The Mac that answered late
  gives its reservation back, the Mac that was never asked is left alone, and
  the pair keeps serving its other requests. A reservation that reaches the
  other Mac too late is refused for that request alone.
- A pair still ends when a Mac or its link is really lost, or when a Mac does
  not answer or give a reservation back in time.
