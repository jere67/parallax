#!/usr/bin/env bash
# Builds release/parallax.jab, the sealed app a JacHammer host serves (see launch.jac), from the
# committed HEAD. It builds in a fresh export because `jac build` also packs ignored files (.env,
# storage/, .jac/cache) from the folder it runs in. Commit the result with the code it was built from.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [ -n "$(git status --porcelain -- . ':!release')" ]; then
  echo "Commit or stash your changes first: the release is built from HEAD." >&2
  exit 1
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git archive HEAD | tar -x -C "$WORK"
mkdir -p "$WORK/.jac/client"
# Reuse this folder's installed dependencies instead of installing them again.
[ -d .jac/venv ] && ln -s "$ROOT/.jac/venv" "$WORK/.jac/venv"
[ -d .jac/client/node_modules ] && cp -R .jac/client/node_modules "$WORK/.jac/client/"
[ -f .jac/client/bun.lock ] && cp .jac/client/bun.lock "$WORK/.jac/client/"
echo "Building the release from $(git rev-parse --short HEAD); this takes several minutes."
(cd "$WORK" && jac build)
mkdir -p release
cp "$WORK/dist/trading-agent.jab" release/parallax.jab
git rev-parse HEAD > release/SOURCE
echo "Wrote release/parallax.jab ($(du -h release/parallax.jab | cut -f1)) from $(cat release/SOURCE)."
