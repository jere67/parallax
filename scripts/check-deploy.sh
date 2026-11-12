#!/bin/sh
# Checks a running Parallax server from outside, the way a visitor reaches it:
#   scripts/check-deploy.sh https://parallax.jaseci.app
# It passes only when the server is up, serves the app, is not a demo, can place orders, sends
# them to Alpaca's paper API, and refuses the admin's fallback password. It needs only curl and
# reads no secret. Exit status 0 when every check passes, 1 otherwise.
set -u
URL=${1:-}
if [ -z "$URL" ]; then
  echo "usage: $0 <server URL>" >&2
  exit 2
fi
URL=${URL%/}
FAILED=0

pass() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; FAILED=1; }

# Each value is matched as JSON prints it, with or without a space after the colon.
has() { printf '%s' "$1" | tr -d ' \n' | grep -q "$2"; }

echo "Checking $URL"

if curl -sf --max-time 20 "$URL/healthz" > /dev/null; then
  pass "the server answers /healthz"
else
  fail "the server does not answer $URL/healthz"
  exit 1
fi

page=$(curl -sf --max-time 20 "$URL/" || true)
if printf '%s' "$page" | grep -q "<title>Parallax"; then
  pass "the app's page is served"
else
  fail "the page at $URL/ is not the Parallax app"
fi

health=$(curl -sf --max-time 20 -X POST "$URL/function/health" -H 'Content-Type: application/json' -d '{}' || true)
if has "$health" '"status":"ok"'; then
  pass "health reports ok"
else
  fail "health did not report ok: $health"
fi
if ! has "$health" '"broker":'; then
  fail "health does not say whether the server can trade: deploy a build with the demo, orders, and broker fields"
else
  if has "$health" '"demo":false'; then
    pass "it is not a demo server"
  else
    fail "it runs in demo mode: unset TRADING_AGENT_DEMO"
  fi
  if has "$health" '"orders":"on"'; then
    pass "orders are on"
  else
    fail "orders are off: unset TRADING_AGENT_DISABLE_ORDERS"
  fi
  if has "$health" '"broker":"paper"'; then
    pass "orders go to Alpaca's paper API"
  else
    fail "orders do not go to Alpaca's paper API: unset ALPACA_BASE_URL"
  fi
fi

# A failed login is harmless; a successful one means anyone can take the admin account.
login=$(curl -s --max-time 20 -X POST "$URL/user/login" -H 'Content-Type: application/json' \
  -d '{"identity":{"type":"username","value":"admin"},"credential":{"type":"password","password":"changeme"}}' || true)
if has "$login" '"token":"'; then
  fail "admin/changeme logs in: set ADMIN_PASSWORD, then change the admin's password"
else
  pass "the admin's fallback password is refused"
fi

if [ "$FAILED" -eq 0 ]; then
  echo "Every check passed."
else
  echo "Some checks failed."
fi
exit "$FAILED"
