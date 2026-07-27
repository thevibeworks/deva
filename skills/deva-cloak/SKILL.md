---
name: deva-cloak
description: Drive CloakBrowser stealth Chromium inside the deva cloak container - a headed, anti-detection browser for scraping, automation, or checking a site the way a real browser sees it. Use when the task needs a browser that bypasses bot detection (Cloudflare, FingerprintJS, reCAPTCHA scoring), or when the user asks to browse/scrape a protected site from inside deva. Only applies in the cloak image (verify with `command -v cloakbrowser`; DEVA_CLOAK=1 is the marker); the base/rust images have plain Playwright instead.
---

# deva-cloak: stealth browser in the deva cloak container

CloakBrowser is a custom-compiled Chromium with source-level fingerprint
patches. Same Playwright API, different binary -- detection sites score it as
a real browser because it is one. This image runs it **headed by default** on a
virtual display, which passes checks that headless fails even with the patches.

## Am I in the cloak context?

This skill only applies when the browser is actually present. ALWAYS run
this check fresh -- never conclude from conversation context, a resumed
session, or `$DEVA_CLOAK` alone (env markers can be scrubbed or stale;
the binary is the ground truth):

```bash
command -v cloakbrowser >/dev/null && cloakbrowser info --quick
```

If that fails, you are in the base or rust image -- there is no CloakBrowser
here. (`DEVA_CLOAK=1` is baked into the cloak image as a convenience marker,
but treat it as a hint, not the test.) Tell the user to relaunch with
`deva.sh -p cloak <agent>`, or use the plain Playwright install (rust image)
instead. Do not try to `npm install cloakbrowser` yourself; the binary is
baked into the cloak image and a runtime install would download ~200MB and
defeat the point.

## What is baked in

- Wrapper + `playwright-core` live in `$CLOAK_APP_DIR` (`/opt/cloak`).
- Chromium binary is pre-downloaded, cache at `/opt/cloakbrowser`, auto-update
  off -- fully offline, no network needed to launch.
- Free binary = **Chromium 146** (58 fingerprint patches). No Pro license.
  Good enough for most sites and for viewing your own apps; the newest
  detection tricks (latest Cloudflare/DataDome) may still win. Pro (146->150,
  71 patches) needs `CLOAKBROWSER_LICENSE_KEY` at runtime -- no rebuild.
- Headed display: Xvfb on `:99` + openbox, started by the entrypoint.
- `x11vnc` for VNC into that display (interactive logins). Start it on demand
  (`x11vnc -display :99 -rfbport 5900 -bg`); on OrbStack/Linux the Mac reaches
  it directly at the container IP -- no port publish, no launch flag.
- `cloak-browserd` always-on browser daemon
  (`/usr/local/lib/cloak/cloak-browserd.mjs`); OPT-IN, runs only with
  `--cloak-browser`, exposes CDP at `CLOAK_CDP_ENDPOINT`. Independent of VNC.

## Running a script

CloakBrowser is ESM-only, so run the script **from `$CLOAK_APP_DIR`** where its
`node_modules` resolves. Write output to absolute workspace paths.

```bash
cd "$CLOAK_APP_DIR"
node --input-type=module <<'EOF'
import { launch } from 'cloakbrowser';

// Headed is the whole point of this image -- keep headless:false for
// detection-heavy sites. Flip to true only for speed on trusted targets.
const browser = await launch({ headless: false });
const page = await browser.newPage();
await page.goto('https://example.com', { waitUntil: 'domcontentloaded' });
console.log(await page.title());
await browser.close();
EOF
```

The returned object is a normal Playwright `Browser` -- `newPage`,
`newContext`, `screenshot`, etc. all work unchanged.

## Options that matter

Pass to `launch({ ... })`:

- `headless: false` -- default posture here; some sites detect headless even
  with the C++ patches.
- `humanize: true` -- human-like mouse curves, per-char typing, scroll. Turn on
  for behavioral detection (deviceandbrowserinfo, reCAPTCHA v3 scoring).
- `proxy: 'http://user:pass@host:port'` or `'socks5://...'` -- residential IPs
  pass reputation checks that datacenter IPs fail. Add `geoip: true` to match
  timezone/locale to the proxy exit IP.
- `args: ['--fingerprint=12345']` -- fixed seed = a consistent returning-visitor
  identity across runs (better for reCAPTCHA v3 than a fresh identity each time).

Recommended stack for a hard anti-bot target:
`launch({ headless: false, humanize: true, proxy: '<residential>', geoip: true })`.

## Authenticated sites: log in over VNC

You cannot copy the host browser's cookie DB in -- Chrome encrypts cookie
values with an OS-keychain key the Linux container can't reach, so the blobs
are undecryptable here. Instead the human logs in once over VNC, watching a
browser YOU (the agent) drive on the cloak display -- same browser, same
profile, persisted to the host.

**The human launches normally -- no VNC flag needed on OrbStack/Linux:**

```bash
deva.sh -p cloak claude
```

**You (the agent) start VNC on demand when a login is needed.** OrbStack (and
native Linux Docker) route the container straight from the host, so a server
you start INSIDE the container is reachable from the Mac with no port publish
and no launch flag:

```bash
x11vnc -display :99 -rfbport 5900 -forever -shared -bg   # add -passwd <pw> to require a password
```

Then tell the human how to connect. The container is reachable from the Mac at
its OrbStack address -- `orb list` on the Mac gives the name/IP, then
`open vnc://<container-ip>:5900` (or `<name>.orb.local:5900`), built-in Screen
Sharing. No `-p`, no recreate.

(`--cloak-vnc` still exists, but only for plain Docker Desktop, where the
container IP is NOT routable from the host and a published loopback port is the
only way in. On OrbStack you don't need it -- and it does not have to be set at
launch.)

**You (the agent) open a headed browser on the display and drive it.** Use a
persistent context on the mounted profile so the login survives:

```bash
cd "$CLOAK_APP_DIR"
node --input-type=module <<'EOF'
import { launchPersistentContext } from 'cloakbrowser';
const ctx = await launchPersistentContext({
  userDataDir: process.env.DEVA_CLOAK_PROFILE_DIR || '/home/deva/.cloak-profile',
  headless: false,   // renders on :99 so the human sees it over VNC
});
const page = ctx.pages()[0] || await ctx.newPage();
await page.goto('https://SITE/login');
// Tell the human: open the printed vnc:// URL and log in (MFA/captcha).
// Wait for the post-login page, then continue -- you hold the same context.
await page.waitForURL('**/app**', { timeout: 300000 });
console.log('logged in:', await page.title());
await ctx.close();   // profile saved to the mounted host dir
EOF
```

The human opens `vnc://127.0.0.1:PORT` (macOS: `open vnc://127.0.0.1:5901`,
built-in Screen Sharing), sees your browser, and logs in. Because you hold the
same persistent context, the session is yours immediately and -- via the
mounted profile -- survives to the next run, even headless with no VNC.

**Optional: always-on shared daemon (`--cloak-browser`).** For a browser that
stays up across agent runs (so the human can log in even when no agent is
active), launch with `--cloak-browser`. deva starts one persistent headed
browser and sets `CLOAK_CDP_ENDPOINT`; attach to it instead of launching your
own -- do NOT `launch()` a second browser, it would miss the login:

```bash
import pw from 'playwright-core';
const b = await pw.chromium.connectOverCDP(process.env.CLOAK_CDP_ENDPOINT);
const ctx = b.contexts()[0];               // the daemon's profile, NOT b.newContext()
const page = ctx.pages()[0] || await ctx.newPage();
await page.goto('https://SITE/app');       // already logged in
await b.close();                           // detaches; the daemon browser stays up
```

`CLOAK_CDP_ENDPOINT` is set only when the daemon runs (`--cloak-browser`); its
absence means there is no daemon and you should launch your own browser as
above.

Use `goto()`, not `setContent()`: on a fresh daemon page `setContent` waits for
a `load` event that never fires and times out. `page.goto('data:text/html,...',
{waitUntil: 'domcontentloaded'})` is the working equivalent for injected markup.

**Persistence / what to mount.** `--cloak-vnc` (and `--cloak-browser`)
auto-mounts `~/.config/deva/cloak-profile` (host) to the Chromium `userDataDir`
`/home/deva/.cloak-profile`. That one dir is the whole session -- cookies,
localStorage, IndexedDB, service workers, Cache, History, Login Data. It
survives container removal, so a login done once is reused by every later run
(even headless, no VNC). Override the host location with
`DEVA_CLOAK_PROFILE_DIR=/path deva.sh -p cloak --cloak-vnc ...`, or mount
your own dir at `/home/deva/.cloak-profile` (your mount wins). Do NOT mount
`/opt/cloakbrowser` -- that is the baked binary, not session data.

Gotcha: only cookies with an `expires` survive a profile reopen -- session
cookies (no expiry) are memory-only. Real logins persist via the site's
long-lived "remember me" / refresh-token cookie, which carries an expiry, so
genuine sessions survive (verified).

**storageState alternative** (no daemon/VNC): if you captured Playwright
storage state elsewhere (cookies + localStorage as plaintext JSON) and mounted
the file, load it into a one-off context -- note the nesting:

```bash
node --input-type=module <<'EOF'
import { launchContext } from 'cloakbrowser';
// storageState MUST be under contextOptions -- launchContext feeds it to
// newContext(). Top-level storageState is silently dropped and you get an
// UNauthenticated browser (verified against cloakbrowser 0.4.x).
const ctx = await launchContext({ headless: false, contextOptions: { storageState: '/home/deva/.cloak-auth/SITE.json' } });
const page = await ctx.newPage();
await page.goto('https://SITE/app');
await ctx.close();
EOF
```

SECURITY -- the profile dir (and any storage-state file) is a live bearer
credential: whoever holds it holds the session. This container runs the agent
with permissions disabled. VNC is auto-passworded; keep it that way. Only keep
the single site the task needs, and never print, log, copy, or write these
files back to a shared/primary account. Treat them as secrets.

## CLI (no script needed)

```bash
cloakbrowser info            # what binary launches, license tier, env checks
cloakbrowser info --quick    # skip the launch test
```

## Gotchas

- Bare `import 'cloakbrowser'` only resolves when cwd is `$CLOAK_APP_DIR`
  (Node ESM resolves bare specifiers from cwd for `--input-type=module`). From
  elsewhere, import the absolute path:
  `import(process.env.CLOAK_APP_DIR + '/node_modules/cloakbrowser/dist/index.js')`.
- Do not run `npx cloakbrowser ...` -- the wrapper is not global; use the
  `cloakbrowser` command (symlinked) or the `$CLOAK_APP_DIR` binary.
- For reCAPTCHA scoring, use native `setTimeout`, not `page.waitForTimeout()`
  (the latter sends CDP traffic reCAPTCHA detects); use `page.type()` not
  `page.fill()` so keystroke events fire.
- CloakBrowser prevents CAPTCHAs; it does not solve them. Bring your own proxy.
