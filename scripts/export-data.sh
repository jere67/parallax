#!/bin/sh
# Exports a Parallax server's records for a move to a new server (site/guide/deploy.md, "Bring
# your records along"):
#   scripts/export-data.sh [folder] [file]
# `folder` is the server's folder, whose database is read (default: this repository); `file` is
# where the export goes (default: parallax-data-<date>.json.gz in the current folder). It reads the
# graph and the sign-in accounts in one snapshot and changes nothing. The file holds password
# hashes and sealed keys: keep it private, and delete it once the move is done.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
FOLDER=$(cd "${1:-$HERE}" && pwd)
OUT=${2:-parallax-data-$(date +%Y-%m-%d).json.gz}
case $OUT in /*) ;; *) OUT=$(pwd)/$OUT ;; esac

if [ ! -f "$FOLDER/jac.toml" ]; then
  echo "export-data: $FOLDER has no jac.toml, so it is not a server's folder" >&2
  exit 2
fi
umask 077
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
(cd "$FOLDER" && jac db sql "$(cat "$HERE/scripts/export-data.sql")") > "$TMP"
if ! head -c 40 "$TMP" | grep -q '"format" *: *"parallax-data"'; then
  echo "export-data: the database did not answer with an export:" >&2
  head -c 400 "$TMP" >&2
  exit 1
fi
gzip -9 -c "$TMP" > "$OUT"
echo "Exported $FOLDER to $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)."
echo "Stop that server before the move, so it does not trade the same account as the new one."
