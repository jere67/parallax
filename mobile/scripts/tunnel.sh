#!/usr/bin/env bash
# Serve the app to Expo Go on a phone that is not on this computer's network.
#
# Opens Cloudflare quick tunnels (temporary https://<random>.trycloudflare.com addresses, no
# account needed) to Metro and to the Parallax servers named, then starts the dev server with
# those addresses, so the sign-in screen offers them with one tap.
#
#   scripts/tunnel.sh             live (port 8100) and demo (port 8200)
#   scripts/tunnel.sh demo        only the demo server
#
# While it runs, anyone who has a tunnel's address reaches that server's sign-in page, as they
# would a deployed one. Ctrl+C closes every tunnel. Needs cloudflared (brew install cloudflared).
set -euo pipefail
cd "$(dirname "$0")/.."

command -v cloudflared > /dev/null || { echo "Install cloudflared first: brew install cloudflared" >&2; exit 1; }
[ -f .jac/mobile-rn/app.config.js ] || { echo "Run scripts/setup.sh first." >&2; exit 1; }

names=("$@")
[ ${#names[@]} -gt 0 ] || names=(live demo)

logs=$(mktemp -d)
pids=()
close_tunnels() {
    [ ${#pids[@]} -eq 0 ] || kill "${pids[@]}" 2> /dev/null || true
    rm -rf "$logs"
}
trap close_tunnels EXIT
trap 'exit 130' INT TERM

# open_tunnel NAME PORT: starts a tunnel to localhost:PORT and sets $url to its address. A
# tunnel's address is random words joined by hyphens; cloudflared also logs its own API's
# address (api.trycloudflare.com), which has none. A request Cloudflare refuses is retried.
open_tunnel() {
    local attempt pid
    url=""
    for attempt in 1 2 3; do
        cloudflared tunnel --no-autoupdate --url "http://localhost:$2" > "$logs/$1.log" 2>&1 &
        pid=$!
        pids+=("$pid")
        for _ in $(seq 1 30); do
            url=$(grep -Eo 'https://[a-z0-9]+(-[a-z0-9]+)+\.trycloudflare\.com' "$logs/$1.log" | head -1 || true)
            [ -n "$url" ] && return 0
            kill -0 "$pid" 2> /dev/null || break
            grep -q "failed to request quick Tunnel" "$logs/$1.log" && break
            sleep 1
        done
        kill "$pid" 2> /dev/null || true
        sleep "$attempt"
    done
    if grep -q "no such host" "$logs/$1.log"; then
        echo "The $1 tunnel did not open: this network's DNS did not find api.trycloudflare.com." >&2
        echo "Some networks block it (the University of Michigan's sometimes does). Join a phone" >&2
        echo "hotspot or another network and run this again, or use scripts/dev.sh on the hotspot." >&2
    else
        echo "The $1 tunnel did not open. cloudflared said:" >&2
        tail -5 "$logs/$1.log" >&2
    fi
    exit 1
}

listening() {
    lsof -nP -iTCP:"$1" -sTCP:LISTEN > /dev/null 2>&1
}

export PARALLAX_LIVE_URL="" PARALLAX_DEMO_URL=""
for name in "${names[@]}"; do
    case "$name" in
        live) port=8100 ;;
        demo) port=8200 ;;
        *) echo "Unknown server '$name'; use live, demo, or both." >&2; exit 2 ;;
    esac
    if ! listening "$port"; then
        echo "Nothing is listening on port $port, so the $name server is left out." >&2
        continue
    fi
    open_tunnel "$name" "$port"
    echo "$name server: $url"
    if [ "$name" = live ]; then PARALLAX_LIVE_URL=$url; else PARALLAX_DEMO_URL=$url; fi
done

if listening 8081; then
    # The dev server would move Metro to the next free port, past the tunnel.
    echo "Port 8081 is taken (another dev server?). Stop it, then run this again." >&2
    exit 1
fi
open_tunnel metro 8081
echo "Metro: $url"
export EXPO_PACKAGER_PROXY_URL=$url

scripts/dev.sh
