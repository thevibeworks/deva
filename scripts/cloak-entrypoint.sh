#!/bin/bash
# CloakBrowser entrypoint: start Xvfb + openbox, then chain to main entrypoint.
# Headed mode by default -- the whole point of the cloak image.

set -e

# Clean stale X lock from previous container instance (survives docker restart
# because /tmp is not tmpfs in this image).
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99

# Start virtual framebuffer (1920x1080, 24-bit color)
Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp &

# Wait for X server to accept connections before starting the window manager.
# Bounded to ~10s -- avoids the race where openbox starts before X is ready.
for _ in $(seq 1 50); do
    DISPLAY=:99 xdotool getdisplaygeometry >/dev/null 2>&1 && break
    sleep 0.2
done

# Window manager so --start-maximized is honored (bare Xvfb has no WM)
DISPLAY=:99 openbox &

export DISPLAY=:99

# Opt-in VNC: expose the Xvfb display so a human can drive the browser for
# interactive logins (MFA/captcha). Off by default -- automated cloak runs
# don't need it and a live display server is needless attack surface.
#
# x11vnc binds 0.0.0.0:5900 inside the container ON PURPOSE: the security
# boundary is deva publishing that port to the HOST loopback only
# (-p 127.0.0.1:PORT:5900). -localhost would bind container loopback, which
# docker's port-proxy can't reach, so the tunnel would be dead.
# DEVA_CLOAK_VNC_PASSWORD adds VNC-level auth on top; without it the display
# is reachable by anything that already reached the host-loopback port.
if [ "${DEVA_CLOAK_VNC:-}" = "1" ]; then
    vnc_auth=(-nopw)
    if [ -n "${DEVA_CLOAK_VNC_PASSWORD:-}" ]; then
        mkdir -p /home/deva/.vnc
        x11vnc -storepasswd "$DEVA_CLOAK_VNC_PASSWORD" /home/deva/.vnc/passwd >/dev/null 2>&1
        chown -R "${DEVA_UID:-1001}:${DEVA_GID:-1001}" /home/deva/.vnc
        vnc_auth=(-rfbauth /home/deva/.vnc/passwd)
    else
        echo "[cloak] WARNING: DEVA_CLOAK_VNC=1 without DEVA_CLOAK_VNC_PASSWORD -- VNC is unauthenticated (reachable only via the host-loopback port deva forwards). Set DEVA_CLOAK_VNC_PASSWORD for defense in depth." >&2
    fi
    # -forever: survive client disconnects; -shared: allow reconnects.
    x11vnc -display :99 -rfbport 5900 -forever -shared -quiet -bg "${vnc_auth[@]}" \
        >/dev/null 2>&1 || echo "[cloak] WARNING: x11vnc failed to start" >&2
    echo "[cloak] VNC server on :5900 (display :99) -- connect via the host port deva forwarded" >&2
fi

# Chain to the standard deva entrypoint
exec /usr/local/bin/docker-entrypoint.sh "$@"
