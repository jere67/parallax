#!/usr/bin/env bash
# Serve the app to Expo Go on a phone on this computer's network: compiles the Jac modules for
# React Native, starts Metro, and prints the QR code to scan. Run scripts/setup.sh once first.
#
# The phone reaches this computer at its network address. When that address is private (an
# iPhone hotspot, a home router), the live (8100) and demo (8200) servers are forwarded to it,
# so servers that listen only on this computer need no restart. On a public address, such as
# a campus network's, nothing is forwarded, since anyone on the internet could then reach them:
# use a hotspot, or scripts/tunnel.sh.
#
# --platform ios is needed because jac.toml sets the app's platform to web (see the comment
# there). Metro serves Android too, so Expo Go on an Android phone works the same way.
set -euo pipefail
cd "$(dirname "$0")/.."

forwarder=""
stop_forwarder() {
    [ -z "$forwarder" ] || kill "$forwarder" 2> /dev/null || true
}
trap stop_forwarder EXIT
trap 'exit 130' INT TERM

address=""
if [ -z "${EXPO_PACKAGER_PROXY_URL:-}" ]; then
    iface=$(route -n get default 2> /dev/null | awk '/interface:/ {print $2}')
    [ -z "$iface" ] || address=$(ipconfig getifaddr "$iface" 2> /dev/null || true)
fi
case "$address" in
    10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[01].*)
        python3 scripts/forward.py "$address" 8100 8200 &
        forwarder=$!
        ;;
    "") ;;
    *)
        echo "  This computer's address ($address) is public, so the servers are not forwarded."
        echo "  A phone can sign in only to a server started with --host 0.0.0.0, or a deployed one."
        ;;
esac

jac run --dev --platform ios "$@"
