#!/bin/bash
# Prepares the Expo project Jac builds the phone app in (.jac/mobile-rn) for Expo Go.
#
# Jac 0.37.12 scaffolds Expo SDK 57, but Expo Go in the App Store runs SDK 58. jac.toml raises
# the scaffold's dependencies; this raises the two dev dependencies jac.toml cannot reach, puts
# in Parallax's dark root shell, app name, and server addresses (expo/), and checks the
# versions with Expo.
set -euo pipefail
cd "$(dirname "$0")/.."
RN=.jac/mobile-rn

jac install
[ -f "$RN/package.json" ] || jac setup

python3 - "$RN" <<'PY'
import json, sys, pathlib
rn = pathlib.Path(sys.argv[1])
pkg = json.loads((rn / "package.json").read_text())
pkg["devDependencies"]["babel-preset-expo"] = "~58.0.0"
pkg["devDependencies"]["@types/react"] = "~19.3.0"
(rn / "package.json").write_text(json.dumps(pkg, indent=2) + "\n")
app = json.loads((rn / "app.json").read_text())
expo = app["expo"]
expo.update({"name": "Parallax", "slug": "parallax", "userInterfaceStyle": "dark", "backgroundColor": "#0c0b09"})
expo["ios"]["bundleIdentifier"] = "app.parallax.mobile"
expo["android"]["package"] = "app.parallax.mobile"
expo["android"]["adaptiveIcon"]["backgroundColor"] = "#0c0b09"
(rn / "app.json").write_text(json.dumps(app, indent=2) + "\n")
PY

cp expo/App.tsx "$RN/app/App.tsx"
cp expo/app.config.js "$RN/app.config.js"

BUN=$(python3 - <<'PY'
import glob, os
hits = sorted(glob.glob(os.path.expanduser("~/.cache/jac/rt/*/site/jaclang/client/_bun/bun")), key=os.path.getmtime)
print(hits[-1] if hits else "bun")
PY
)
(cd "$RN" && "$BUN" install && "$BUN" node_modules/expo/bin/cli install --check)
echo "Ready. Start it with scripts/dev.sh (same Wi-Fi) or scripts/tunnel.sh (any network)."
