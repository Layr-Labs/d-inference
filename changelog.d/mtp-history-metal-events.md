### Drafting models no longer use up Metal shared events while several requests decode

- While two or more requests decoded together on one model, each decode step left one Metal shared event alive. The count fell only when one request drafted alone or the requests ended. This hit Qwen 3.8 by default; the 9B, the 35B and Qwen 3.6 when a client sent `presence_penalty: 0`; Lightning; and Qwen4 Flash-Next. Two Qwen 3.8 requests added about 2,000 events a minute. Shared events are a finite system-wide pool. After roughly 15–50 minutes of such a stretch, the provider could abort with `Failed to create Metal shared event`.
- The SDK now drops each finished step's event from the arrays the drafting history keeps. Tokens and drafts are unchanged, and no GPU work is added.
