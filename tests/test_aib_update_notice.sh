#!/usr/bin/env bash
# aib tells about a newer release by itself (2026-11-25: a new aib went
# unnoticed until Homebrew's tap was refreshed by hand — Homebrew reads its
# local copy of the tap, which `brew update` refreshes by itself at most once
# a day, and aib only looked when someone ran `aib update`).
# A daily background lookup in a terminal feeds a one-line notice; the
# command never waits for it, and hooks and `aib version` never show it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AIB="$ROOT/bin/aib"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
export HOME="$TMP/home" AIB_REGISTRY="$TMP/registry.json"
mkdir -p "$HOME/.aib"; echo '[]' > "$AIB_REGISTRY"
unset AIB_NO_UPDATE_CHECK AIB_LATEST_VERSION AIB_ASSUME_TTY
CACHE="$HOME/.aib/latest-release"
current="$("$AIB" version | sed 's/^aib v//')"
newer="99.0.0"
cd "$TMP"

status_tty() { AIB_ASSUME_TTY=1 "$AIB" status 2>&1 >/dev/null; }
wait_cache() { for _ in $(seq 50); do [ "$(sed -n 2p "$CACHE" 2>/dev/null)" = "$1" ] && return 0; sleep 0.1; done; return 1; }
old_cache() { printf '1\n%s\n' "$1" > "$CACHE"; }

# 1. No lookup yet: the command does not wait; the lookup runs in the
#    background, and the next command names the newer aib.
export AIB_LATEST_VERSION="$newer"
out="$(status_tty)"
echo "$out" | grep -q "is out" && fail "notice before any lookup: $out"
wait_cache "$newer" || fail "background lookup did not record $newer: $(cat "$CACHE" 2>/dev/null)"
out="$(status_tty)"
echo "$out" | grep -q "aib $newer is out" || fail "newer aib not named: $out"
echo "$out" | grep -q "aib update" || fail "notice does not say how to update: $out"

# 2. Looked up today: no second lookup until a day has passed.
printf '%s\n%s\n' "$(date +%s)" "$current" > "$CACHE"
status_tty >/dev/null; sleep 1
[ "$(sed -n 2p "$CACHE")" = "$current" ] || fail "looked up again within a day"

# 3. Up to date: nothing said.
out="$(status_tty)"
echo "$out" | grep -q "is out" && fail "notice while up to date: $out"

# 4. Outside a terminal (CommandCenter, scripts): nothing said, nothing looked up.
old_cache "$newer"
out="$("$AIB" status 2>&1 >/dev/null)"
echo "$out" | grep -q "is out" && fail "notice outside a terminal: $out"
sleep 1; [ "$(sed -n 1p "$CACHE")" = 1 ] || fail "looked up outside a terminal"

# 5. Never in `aib version` (CommandCenter reads the version from it) or hooks.
out="$(AIB_ASSUME_TTY=1 "$AIB" version 2>&1)"
[ "$out" = "aib v$current" ] || fail "aib version printed more than the version: $out"
mkdir -p "$TMP/barrack"; touch "$TMP/barrack/agent.yaml"
out="$(cd "$TMP/barrack" && echo '{}' | AIB_ASSUME_TTY=1 AIB_LIVE_PID=$$ AIB_LIVE_LSTART=test "$AIB" hook start claude 2>&1)"
echo "$out" | grep -q "is out" && fail "hook output carries the notice: $out"

# 6. AIB_NO_UPDATE_CHECK=1 turns it off.
out="$(AIB_NO_UPDATE_CHECK=1 AIB_ASSUME_TTY=1 "$AIB" status 2>&1 >/dev/null)"
echo "$out" | grep -q "is out" && fail "notice despite AIB_NO_UPDATE_CHECK=1: $out"

# 7. Offline: the known release is kept (and not looked up again for a day).
unset AIB_LATEST_VERSION
export AIB_LATEST_URL="http://127.0.0.1:9/offline"
old_cache "$newer"
status_tty >/dev/null
for _ in $(seq 50); do [ "$(sed -n 1p "$CACHE")" != 1 ] && break; sleep 0.1; done
[ "$(sed -n 1p "$CACHE")" != 1 ] || fail "offline lookup not recorded"
[ "$(sed -n 2p "$CACHE")" = "$newer" ] || fail "offline lookup forgot the known release: $(cat "$CACHE")"
sleep 1; [ "$(sed -n 2p "$CACHE")" = "$newer" ] || fail "offline lookup forgot the known release later: $(cat "$CACHE")"

# 8. Many commands at once (CommandCenter restoring its panes): one lookup.
mkdir -p "$TMP/stub"
cat > "$TMP/stub/curl" <<EOF
#!/bin/sh
echo x >> "$TMP/lookups"
sleep 1
echo '{"tag_name":"v$newer"}'
EOF
chmod +x "$TMP/stub/curl"
old_cache "$current"
for _ in 1 2 3 4 5; do PATH="$TMP/stub:$PATH" status_tty >/dev/null; done
wait_cache "$newer" || fail "lookup through GitHub's answer not recorded: $(cat "$CACHE")"
[ "$(wc -l < "$TMP/lookups" | tr -d ' ')" = 1 ] || fail "$(wc -l < "$TMP/lookups" | tr -d ' ') lookups for 5 commands in a row"

echo "PASS: aib update notice (background daily lookup, once, terminal only, never in version/hooks, opt-out, offline)"
