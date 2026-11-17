### Nemotron 3.5 Super refuses at once what it can't start in time

- A Nemotron Super Mac now turns down, at once, a network request whose first output its own recent speed says it can't deliver before the time the network gave it. The request is moved to another Mac with almost all of that time left, instead of being held here until the time runs out and then failing. This matters most on slower Macs with long image or text prompts when the network is busy.
- Your own requests (on this Mac, your other Macs or a pair) never carry such a time limit and are never turned down this way.
- `DARKBLOOM_NEMOTRON_SUPER_FIRST_CONTENT_REFUSAL=0` (or `off`) starts every request again, as 0.10.14 did.
