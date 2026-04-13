# Custom Images

This is the guide for people who want their own deva image instead of
the stock one.

Common reasons:

- you want extra tools baked in
- you want a personal image in your own registry
- you want local experiments without waiting for upstream releases

That is fine. deva does not care where the image came from. It cares
that the image exists and that the tag you asked for is real.

## The Two Knobs

Deva picks the runtime image from two host-side variables:

- `DEVA_DOCKER_IMAGE`
- `DEVA_DOCKER_TAG`

If you do nothing, it uses:

```text
DEVA_DOCKER_IMAGE=ghcr.io/thevibeworks/deva
DEVA_DOCKER_TAG=latest
```

For the rust profile, the default tag becomes `rust`.

Important detail:

- if you set only `DEVA_DOCKER_IMAGE`, `PROFILE=rust` can still change the
  tag to `rust`
- if you want zero surprises, set both `DEVA_DOCKER_IMAGE` and
  `DEVA_DOCKER_TAG`

## Build A Local Image

Supported path:

```bash
make build-main
make build-rust
```

If you only changed the late agent-install layer and want the fastest rebuild:

```bash
make build-core
make build-rust-image
```

`build-rust-image` uses the local `:core` image as its parent so late
changes to the agent layer do not force the Rust apt layer to rerun.

Manual `docker build` is still possible, but it is an advanced path now.
Do not rely on the Dockerfile defaults for release images. Pass explicit
tool versions, and point the Rust build at the local core image:

```bash
bash ./scripts/resolve-tool-versions.sh

docker build -t deva-local:latest \
  --build-arg CLAUDE_CODE_VERSION=<claude_code_version> \
  --build-arg CODEX_VERSION=<codex_version> \
  --build-arg GEMINI_CLI_VERSION=<gemini_cli_version> \
  --build-arg ATLAS_CLI_VERSION=<atlas_cli_version> \
  --build-arg COPILOT_API_VERSION=<copilot_api_version> \
  --build-arg GO_VERSION=1.26.2 \
  .

docker build -f Dockerfile --target agent-base -t deva-local:core .

docker build -f Dockerfile.rust -t deva-local:rust \
  --build-arg BASE_IMAGE=deva-local:core \
  --build-arg CLAUDE_CODE_VERSION=<claude_code_version> \
  --build-arg CODEX_VERSION=<codex_version> \
  --build-arg GEMINI_CLI_VERSION=<gemini_cli_version> \
  --build-arg ATLAS_CLI_VERSION=<atlas_cli_version> \
  --build-arg PLAYWRIGHT_VERSION=<playwright_version> \
  --build-arg PLAYWRIGHT_MCP_VERSION=<playwright_mcp_version> \
  .
```

Then run deva against it:

```bash
DEVA_DOCKER_IMAGE=deva-local \
DEVA_DOCKER_TAG=latest \
deva.sh codex
```

Or for the rust image:

```bash
DEVA_DOCKER_IMAGE=deva-local \
DEVA_DOCKER_TAG=rust \
deva.sh claude
```

Deva checks local images first. If the image is already there, it does
not need to pull anything.

## Build A Personal Registry Image

If you want your own registry namespace, tag it that way from the start:

```bash
docker build -t ghcr.io/yourname/deva:daily .
docker push ghcr.io/yourname/deva:daily
```

Then point deva at it:

```bash
export DEVA_DOCKER_IMAGE=ghcr.io/yourname/deva
export DEVA_DOCKER_TAG=daily
deva.sh codex
```

That is the whole trick. This is not Kubernetes. It is just an image
name plus a tag.

If you want the same fast layering in your own registry for downstream
profile builds, publish a `core` tag too and make the Rust image inherit
from that instead of from the full `latest` image.

## Keep It Personal

If this is only for you, put the override in `.deva.local`:

```text
DEVA_DOCKER_IMAGE=ghcr.io/yourname/deva
DEVA_DOCKER_TAG=daily
```

That file is the right place for personal registry tags, private images,
and "I am trying weird stuff" experiments.

If the whole team should use the same custom image, put it in `.deva`
instead:

```text
DEVA_DOCKER_IMAGE=ghcr.io/acme/deva
DEVA_DOCKER_TAG=team-rust-20260312
```

Yes, deva's config loader will export those variables for the wrapper.
That is intentional.

## Extend The Official Image Instead Of Starting From Nothing

If you just need a few extra tools, do not rebuild the universe.

Use the published image as your base:

```dockerfile
FROM ghcr.io/thevibeworks/deva:latest

RUN apt-get update && apt-get install -y --no-install-recommends \
    graphviz \
    postgresql-client \
 && rm -rf /var/lib/apt/lists/*
```

Build and run it:

```bash
docker build -t deva-local:extras .
DEVA_DOCKER_IMAGE=deva-local DEVA_DOCKER_TAG=extras deva.sh gemini
```

That is usually the sane move.

## Rust Image Includes Browser Tooling

The rebuilt `rust` profile now bakes in:

- `bubblewrap` for Claude Code subprocess isolation on Linux
- Go `1.26.2`
- Playwright CLI and Playwright MCP
- Playwright browsers installed in-image
- Google Chrome stable on `linux/amd64`

Important detail:

- Google Chrome's official Linux `.deb` is available for `amd64`
- on `arm64`, the image still has Playwright Chromium/Firefox/WebKit, but not `google-chrome-stable`

If you only bump `claude-code`, `codex`, or `gemini`, the Rust build should mostly reuse cached lower layers. The browser/toolchain layers sit below the volatile agent install layer on purpose.

## What Still Comes From The Wrapper

Changing the image does not change the wrapper model.

Deva still controls:

- workspace mounts
- auth mounts
- config-home wiring
- container naming
- persistent vs ephemeral behavior
- debug and dry-run output

So a custom image is not a custom launcher. It is just a different root
filesystem under the same wrapper behavior.

## Personal Use Without Installing Anything Globally

You do not need to replace your whole system install.

Per-shell:

```bash
DEVA_DOCKER_IMAGE=deva-local \
DEVA_DOCKER_TAG=latest \
deva.sh codex
```

Per-project:

```text
# .deva.local
DEVA_DOCKER_IMAGE=deva-local
DEVA_DOCKER_TAG=latest
```

That way your personal image only affects the project where you meant to
use it. Amazing concept.

## Gotchas

- If you set only the image and forget the tag, profile defaults may
  still pick `latest` or `rust`.
- If the image is private, pulls need auth. Public docs pointing at a
  private image are broken by definition.
- If you build a custom image that removes expected tools or paths,
  deva will not magically repair your bad Dockerfile.
- If your image tag does not exist locally and cannot be pulled, deva
  fails fast. Good. Silent nonsense would be worse.

## Sanity Check

Use this before blaming the wrapper:

```bash
DEVA_DOCKER_IMAGE=deva-local \
DEVA_DOCKER_TAG=latest \
deva.sh codex --debug --dry-run
```

If the printed image is wrong, your override is wrong.
If the printed image is right, the problem is somewhere else.
