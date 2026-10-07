#!/bin/bash
# Render templates/ into rendered/, replacing __NAME__ tokens with values from .env.
# Works with bash 3.2 (macOS) and BWK awk. Never deletes files in rendered/.
set -euo pipefail

usage() { echo "usage: $0 [--check] [--env FILE]" >&2; exit 64; }

root="$(cd "$(dirname "$0")" && pwd)"
env_file="$root/.env"
check=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) check=1 ;;
    --env) shift; [ $# -gt 0 ] || usage; env_file="$1" ;;
    *) usage ;;
  esac
  shift
done

if [ ! -f "$env_file" ]; then
  echo "render: $env_file not found. Copy .env.example to .env and fill it in." >&2
  exit 1
fi

if [ "$check" -eq 1 ]; then
  out="$(mktemp -d)"
  trap 'rm -rf "$out"' EXIT
else
  out="$root/rendered"
fi
mkdir -p "$out"
# Rendered files hold secrets, so only the owner may enter the directory.
chmod 700 "$out"

(cd "$root/templates" && find . -type f ! -name .gitkeep) | while IFS= read -r rel; do
  rel="${rel#./}"
  mkdir -p "$out/$(dirname "$rel")"
  awk -v envfile="$env_file" '
    BEGIN {
      q = sprintf("%c", 39)
      while ((getline line < envfile) > 0) {
        sub(/\r$/, "", line)
        if (line !~ /^[A-Z0-9_]+=/) continue
        k = substr(line, 1, index(line, "=") - 1)
        v = substr(line, index(line, "=") + 1)
        # One pair of double or single quotes is stripped; an unquoted value
        # loses a trailing " # comment".
        # A double-quoted value ends at its closing quote; anything after is dropped.
        if (v ~ /^"/ && (n = index(substr(v, 2), "\"")) > 0) v = substr(v, 2, n - 1)
        else if (length(v) >= 2 && substr(v, 1, 1) == q && substr(v, length(v), 1) == q) v = substr(v, 2, length(v) - 2)
        else sub(/[ \t]+#.*$/, "", v)
        if (v != "") vals[k] = v
      }
    }
    {
      s = $0; res = ""
      while (match(s, /__[A-Z0-9_]+__/)) {
        name = substr(s, RSTART + 2, RLENGTH - 4)
        rep = (name in vals) ? vals[name] : substr(s, RSTART, RLENGTH)
        res = res substr(s, 1, RSTART - 1) rep
        s = substr(s, RSTART + RLENGTH)
      }
      print res s
    }' "$root/templates/$rel" > "$out/$rel"
done

left="$( (cd "$root/templates" && find . -type f ! -name .gitkeep) | while IFS= read -r rel; do
  rel="${rel#./}"
  grep -nE '__[A-Z0-9_]+__' "$out/$rel" | sed "s|^|$rel:|" || true
done )"
if [ -n "$left" ]; then
  echo "render: unfilled tokens (set them in $env_file):" >&2
  echo "$left" >&2
  exit 1
fi

if [ "$check" -eq 1 ]; then echo "render: ok (check only)"; else echo "render: wrote $out"; fi
