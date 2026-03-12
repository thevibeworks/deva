# Security Policy

## Supported Versions

We support:

| Version | Status |
| --- | --- |
| latest release | supported |
| `main` | best effort |
| older tags | no guarantees |

If you are filing a security report against an old tag, reproduce it on the latest release first.

## Report a Vulnerability

Do not open a public GitHub issue for security problems.

Preferred path:

- GitHub private vulnerability reporting, if it is enabled for the repo

Fallback:

- email: `wrqatw@gmail.com`

Include:

- affected version or commit
- exact command or config that triggers the problem
- what the impact is
- whether secrets, host files, or container boundaries are involved
- logs, screenshots, or proof-of-concept if you have them

## What Counts

We care about:

- container escape or host privilege escalation
- auth bypass or auth mix-up
- secret leakage
- unsafe default mounts
- command injection
- release or installer supply-chain issues

We care less about:

- theoretical issues with no realistic exploit path
- self-inflicted damage from mounting your whole home and then giving the agent full power

That second one is not a clever exploit. That is just bad operational judgment.

## Response Expectations

Best effort, not corporate theater.

- acknowledgement target: within 7 days
- status updates when there is real progress
- coordinated disclosure after a fix lands

## Safe Harbor

If you act in good faith, avoid data destruction, and do not exfiltrate other people's data, we will treat your report as research, not abuse.
