#!/bin/bash
# Tests for render.sh. Runs under macOS /bin/bash 3.2 on purpose.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$3] got [$2]"; fail=1; fi; }

setup() {
  T="$(mktemp -d)"
  cp "$ROOT/render.sh" "$T/"
  mkdir -p "$T/templates/02-x/.well-known"
  printf 'name: __SERVER_NAME__\nhost: "__HS_HOST__"\n' > "$T/templates/02-x/conf.yaml"
  printf '{"h": "__HS_HOST__"}\n' > "$T/templates/02-x/.well-known/client"
}

setup
printf 'SERVER_NAME=example.com\nHS_HOST="mesh-host.example.net"\n' > "$T/.env"
(cd "$T" && /bin/bash ./render.sh >/dev/null 2>&1); check "renders with bash 3.2" "$?" "0"
check "replaces token" "$(sed -n 1p "$T/rendered/02-x/conf.yaml")" "name: example.com"
check "strips quotes" "$(sed -n 2p "$T/rendered/02-x/conf.yaml")" 'host: "mesh-host.example.net"'
check "renders hidden dirs" "$(cat "$T/rendered/02-x/.well-known/client")" '{"h": "mesh-host.example.net"}'
chmod 755 "$T/rendered"; (cd "$T" && /bin/bash ./render.sh >/dev/null 2>&1)
check "rendered dir is 700" "$(find "$T/rendered" -maxdepth 0 -perm 700 | wc -l | tr -d ' ')" "1"

touch "$T/rendered/sentinel"
(cd "$T" && /bin/bash ./render.sh >/dev/null 2>&1)
check "never deletes in rendered/" "$([ -f "$T/rendered/sentinel" ] && echo kept)" "kept"

setup
printf 'SERVER_NAME=example.com\nHS_HOST=\n' > "$T/.env"
(cd "$T" && /bin/bash ./render.sh >/dev/null 2>&1); check "empty value fails" "$?" "1"

setup
printf 'SERVER_NAME=example.com\n' > "$T/.env"
out="$(cd "$T" && /bin/bash ./render.sh 2>&1)"; code=$?
check "missing key fails" "$code" "1"
check "names the file" "$(echo "$out" | grep -c '02-x/conf.yaml:2')" "1"

setup
printf 'SERVER_NAME=example.com\nHS_HOST=h.example.net\n' > "$T/.env"
(cd "$T" && /bin/bash ./render.sh --check >/dev/null 2>&1); check "check mode passes" "$?" "0"
check "check mode writes nothing" "$([ -d "$T/rendered" ] && echo wrote || echo none)" "none"

(cd "$T" && rm .env && /bin/bash ./render.sh >/dev/null 2>&1); check "missing .env fails" "$?" "1"

setup
printf 'SERVER_NAME=example.com\r\nHS_HOST="mesh-host.example.net"\r\n' > "$T/.env"
(cd "$T" && /bin/bash ./render.sh >/dev/null 2>&1); check "crlf env renders" "$?" "0"
check "crlf name line" "$(sed -n 1p "$T/rendered/02-x/conf.yaml")" "name: example.com"
check "crlf host line" "$(sed -n 2p "$T/rendered/02-x/conf.yaml")" 'host: "mesh-host.example.net"'
check "crlf leaves no CR" "$(grep -c "$(printf '\r')" "$T/rendered/02-x/conf.yaml")" "0"

setup
printf 'SERVER_NAME=example.com\nHS_HOST=h.example.net\n' > "$T/.env"
mkdir -p "$T/rendered"; printf '__OLD__\n' > "$T/rendered/stale.txt"
(cd "$T" && /bin/bash ./render.sh >/dev/null 2>&1); check "stale file ignored" "$?" "0"
check "stale file kept" "$([ -f "$T/rendered/stale.txt" ] && echo kept)" "kept"

setup
printf 'SERVER_NAME=example.com # the server name\nHS_HOST=%smesh-host.example.net%s\n' "'" "'" > "$T/.env"
(cd "$T" && /bin/bash ./render.sh >/dev/null 2>&1); check "comment and single quotes render" "$?" "0"
check "strips inline comment" "$(sed -n 1p "$T/rendered/02-x/conf.yaml")" "name: example.com"
check "strips single quotes" "$(sed -n 2p "$T/rendered/02-x/conf.yaml")" 'host: "mesh-host.example.net"'

setup
printf 'SERVER_NAME="example.com # kept"\nHS_HOST=h.example.net#kept\n' > "$T/.env"
(cd "$T" && /bin/bash ./render.sh >/dev/null 2>&1)
check "quoted hash kept" "$(sed -n 1p "$T/rendered/02-x/conf.yaml")" "name: example.com # kept"
check "unspaced hash kept" "$(sed -n 2p "$T/rendered/02-x/conf.yaml")" 'host: "h.example.net#kept"'

setup
printf 'SERVER_NAME=example.com\nHS_HOST="mesh-host.example.net" # note\n' > "$T/.env"
(cd "$T" && /bin/bash ./render.sh >/dev/null 2>&1)
check "comment after double quotes" "$(sed -n 2p "$T/rendered/02-x/conf.yaml")" 'host: "mesh-host.example.net"'

exit $fail
