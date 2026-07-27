// cloak-browserd - always-on CloakBrowser daemon.
//
// Holds ONE persistent, headed, stealth browser on the cloak display (:99)
// with a loopback CDP endpoint. The human watches and drives it over VNC; the
// agent attaches with Playwright `connectOverCDP(CLOAK_CDP_ENDPOINT)` and
// drives the SAME live browser + profile -- so a login done once (by the human
// over VNC, or the agent) is immediately usable by the other, and persists in
// the mounted userDataDir. Started by docker-entrypoint when
// DEVA_CLOAK_BROWSER=1; relaunches if the browser dies.
//
// Absolute import (not bare 'cloakbrowser'): this file lives outside
// $CLOAK_APP_DIR, so ESM bare-specifier resolution from cwd would miss it.
const appDir = process.env.CLOAK_APP_DIR || '/opt/cloak';
const { launchPersistentContext } = await import(
  appDir + '/node_modules/cloakbrowser/dist/index.js'
);

const userDataDir = process.env.DEVA_CLOAK_PROFILE_DIR || '/home/deva/.cloak-profile';
const port = Number(process.env.DEVA_CLOAK_CDP_PORT || 9222);

let ctx = null;
let stopping = false;

async function start() {
  ctx = await launchPersistentContext({
    userDataDir,
    headless: false, // visible on :99 for VNC; the whole point of the cloak image
    // --remote-debugging-port opens the loopback CDP endpoint the agent attaches
    // to; -address pins it to loopback so it never leaves the container.
    args: [`--remote-debugging-port=${port}`, '--remote-debugging-address=127.0.0.1'],
  });
  if (ctx.pages().length === 0) await ctx.newPage();
  console.log(`[cloak-browserd] up: CDP http://127.0.0.1:${port} profile=${userDataDir}`);
  ctx.on('close', () => {
    if (stopping) return;
    console.log('[cloak-browserd] browser closed; relaunching in 1s');
    setTimeout(() => start().catch(fail), 1000);
  });
}

function fail(e) {
  console.error('[cloak-browserd] fatal:', (e && e.stack) || e);
  process.exit(1);
}

for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, async () => {
    stopping = true;
    try { await ctx?.close(); } catch { /* already gone */ }
    process.exit(0);
  });
}

// Keep the event loop alive across a relaunch gap even if all other handles clear.
setInterval(() => {}, 1 << 30);

start().catch(fail);
