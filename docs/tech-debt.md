# Tech debt

## Deny reads of the VM Claude's credential files

The Remote Control service runs in auto mode (`--permission-mode auto`). The classifier
checks each action, but the docs say it is not an isolation boundary. A prompt-injected
session could read `~/.codex/auth.json`, `~/.config/gh/hosts.yml` or the Claude login
credentials and send them out.

- **Fix:** add `permissions.deny` rules to the `/etc/claude-remote-settings.json` heredoc
  in `setup_claude_service`, e.g. `Read(~/.codex/auth.json)`, `Read(~/.config/gh/hosts.yml)` and the Claude
  credentials file.
- **Unverified:** the Claude credentials file name under `~/.claude` on the VM. Check it
  with `sudo ls -a /home/claude/.claude` before writing the rule.
- **Limit:** this stops only the Read tool. `cat` in Bash still works unless the Bash
  sandbox is on (next item).

## Bash sandbox with a domain allowlist (only if needed)

Do this only when sessions run unattended for long periods, or when the item above is not
enough. Enable `sandbox.enabled`, `autoAllowBashIfSandboxed` and
`sandbox.network.allowedDomains`, and install the sandbox's Linux dependencies in
`startup.sh`. Never allowlist the WARP proxy (`127.0.0.1:40000`): it is a SOCKS5 proxy to
any host, so allowing it opens the whole network.
