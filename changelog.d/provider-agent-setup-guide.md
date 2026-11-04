### A setup prompt for AI agents

- New provider how-to, `docs/provider/agent-setup.md`, written to be given to an AI agent ("point your agent at this file"). The agent installs and checks the signed release, logs in with the person's help, and either serves on one Mac or pairs two Macs over a Thunderbolt 5 cable. It then proves the result with status lines, the pair's log and a test request, instead of trusting the setup screen alone.
- It lists, up front, the steps only the person can do: the Terms of Service, the Darkbloom login, the RDMA switch, the macOS password and Local Network prompts, the pairing code and Screen Sharing for headless Macs. It also lists the agent's safety rules: no security settings changed, no Darkbloom files or Keychain items deleted by hand, no `darkbloom cluster link --remove` unless asked, and no large download without asking.
- Documentation only: no provider artifact changes.
