# Contributing

Thanks. Keep it tight.

## Before You Send Anything

- open or find the issue first
- keep one branch per issue
- read the workflow docs in `workflows/`

Use these, not your imagination:

- `workflows/GITHUB-ISSUE.md`
- `workflows/GITHUB-PR.md`
- `workflows/GIT-COMMIT.md`
- `workflows/RELEASE.md`

## Local Checks

Run the obvious stuff before you ask anyone else to look:

```bash
./deva.sh --help
./deva.sh --version
./claude-yolo --help
./scripts/version-check.sh
shellcheck deva.sh agents/*.sh docker-entrypoint.sh install.sh scripts/*.sh
```

If you change Docker image behavior, auth flows, or release logic, test those paths directly. Do not ship "should work".

## What We Want

- small, focused changes
- direct docs
- boring shell scripts that still work tomorrow
- explicit auth and mount behavior
- no surprise regressions

## What We Do Not Want

- prompt-engineering fluff in docs
- magical wrappers around simple shell code
- untested auth changes
- random formatting churn
- force-push chaos on shared branches

## Docs Rules

Update docs when behavior changes:

- `README.md` for the front page and project positioning
- `docs/` for long-form user guides
- `CHANGELOG.md` for release notes
- `DEV-LOGS.md` for significant work
- `SECURITY.md` when the reporting path or threat model changes

## Pull Requests

A good PR does three things:

1. says what changed
2. says why it changed
3. says how you tested it

If it touches auth, container boundaries, or release mechanics, include the exact command you ran.

## Releases

Do not freestyle releases.

Follow `workflows/RELEASE.md`. Update version, changelog, and docs together, then tag the release. If the tree is dirty and you do not understand why, stop.
