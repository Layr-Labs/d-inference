### A long-running request no longer drops the provider's connection to Darkbloom

- While the provider handled one incoming message, it read nothing else from its connection to Darkbloom. When handling
  took longer than 6 seconds, for example a large image request on a busy Mac, the provider saw no answer to its own
  keep-alive pings, decided the connection was dead and reconnected, cancelling every request in flight on it.
- The provider now keeps reading its connection while it handles a message, and waits 20 seconds without any sign of
  life before it declares the connection dead (6 seconds before). A coordinator node that disappears is still found in
  about 20 seconds.
- When the provider does drop a connection it judged dead, it first tells Darkbloom why with a close code (4001; 4002
  after the Mac slept), so these drops can be told apart from network failures.
