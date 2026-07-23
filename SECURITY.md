# Security Policy

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting on this repository
(Security ▸ Report a vulnerability) rather than a public issue. You should get a
response within a few days.

## Scope notes

AgentBar's remote-approval feature is security-relevant by nature. Design
guarantees worth knowing when auditing:

- Everything is same-user, local filesystem — there is no network surface.
  The app ↔ hook protocol is JSON files under `~/.agentbar/`.
- "Always allow" can only persist a rule that Claude Code itself suggested for
  that request: the hook structurally compares the answer's rule against the
  received `permission_suggestions` and downgrades anything else to a one-shot
  allow (`Scripts/hooks/claude/permission.js`).
- Every failure path (app missing, killed hook, timeout, malformed files)
  degrades to the agent's normal interactive prompt — never to an approval.
- Keystroke approval for non-Claude agents requires the user to grant the
  Accessibility permission and a per-prompt click on an explicitly labeled item.

Reports that break any of these guarantees are exactly what we want to hear about.
