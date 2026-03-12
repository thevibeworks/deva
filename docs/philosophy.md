# Philosophy

Tools like this go bad when they start lying about what they are.

`deva.sh` tries not to do that.

## The Container Is The Sandbox

The whole design starts here.

We do not rely on the agent's interactive approval prompts as the main safety story. We run the agent inside Docker and make the host boundary explicit with mounts and env vars.

That has consequences:

- inside the container, the agent gets broad power
- outside the container, it only sees what we mounted or forwarded
- the quality of the boundary depends on the mounts you chose, not on wishful thinking

If you punch holes through that boundary with `docker.sock`, host networking, or your entire home directory, that is your decision. The docs should say that plainly.

## Explicit Beats Magical

Hidden config and silent fallback behavior are where auth bugs and secret leaks come from.

So deva prefers:

- explicit mount lists
- explicit auth method switches
- explicit config homes
- explicit debug output

When auth changes, the container identity changes too. When non-default auth is active, the default credential file gets masked. That is boring, and boring is good.

## Persistent Beats Disposable

One-shot containers look neat in demos and get old fast in real work.

Persistent per-project containers mean:

- warm package caches
- stateful shell history and scratch space
- fast switching between Claude, Codex, and Gemini

`--rm` still exists. It just is not the default because the default should serve real work instead of screenshots.

## Separate Auth Homes Beat Shared Mess

Most auth trouble comes from mixing identities:

- personal and work credentials
- OAuth state and API keys
- one agent's config assumptions with another's

`~/.config/deva/` exists to stop that drift. `--config-home` exists when you need even harder separation.

## Shell Script Over Platform Theater

This repo is mostly shell because the job is orchestration, not empire-building.

That means:

- easy to inspect
- easy to patch
- easy to debug with `--dry-run`
- hard to hide nonsense in ten abstraction layers

You can absolutely write bad shell. Plenty of people do. But for this job, a readable shell script is still better than building a fake platform because someone got bored.

## Multi-Agent, Not Single-Vendor

This started in the Claude world. It would have been stupid to stay trapped there.

The useful abstraction is not "Claude but renamed." The useful abstraction is:

- one container workflow
- several agents
- explicit auth and model wiring per agent

That is why `deva.sh` is the entry point and the old wrappers are just compatibility shims.

## Honest Docs Or Nothing

The docs should tell you:

- what works
- what is sharp
- what is slower than you expect
- what the wrapper does on your behalf

If the docs skip the ugly parts, then they are marketing. We do not need more marketing.
