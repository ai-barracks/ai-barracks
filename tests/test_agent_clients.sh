#!/usr/bin/env bash
# Finding and installing claude/codex (2026-11-25: on a new Mac aib could not
# find claude — a GUI app's login shell skips ~/.zshrc, where installers put
# ~/.local/bin; this Mac's app ran a stale Homebrew Claude instead).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AIB="$ROOT/bin/aib"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"   # no claude/codex here (jq is /usr/bin/jq)
command -v jq >/dev/null || fail "jq required"
JQ_DIR="$(dirname "$(command -v jq)")"
export PATH="$BASE_PATH:$JQ_DIR" HOME="$TMP/home"; mkdir -p "$HOME"

# A fake client: prints its name, version and PATH when run.
fake() { # dir name version
    mkdir -p "$1"
    printf '#!/bin/sh\n[ "$1" = --version ] && { echo "%s (fake)"; exit 0; }\necho "ran %s PATH=$PATH"\n' "$3" "$2" > "$1/$2"
    chmod +x "$1/$2"
}

# 1. Not on PATH: found in an install folder (as ~/.local/bin on a new Mac).
fake "$TMP/native" claude 2.1.331
export AIB_CLIENT_DIRS="$TMP/empty:$TMP/native"
found="$(AIB_SOURCE_ONLY=1 bash -c "source '$AIB'; _aib_find_client claude")"
[ "$found" = "$TMP/native/claude" ] || fail "claude off PATH not found: '$found'"

# 2. PATH wins; every install is listed once (a symlink is the same install).
fake "$TMP/brew" claude 2.1.118
mkdir -p "$TMP/linked"; ln -s "$TMP/native/claude" "$TMP/linked/claude"
all="$(PATH="$TMP/brew:$PATH" AIB_CLIENT_DIRS="$TMP/linked:$TMP/native" AIB_SOURCE_ONLY=1 bash -c "source '$AIB'; _aib_client_all claude")"
[ "$(echo "$all" | head -1)" = "$TMP/brew/claude" ] || fail "PATH's install not first: $all"
[ "$(echo "$all" | wc -l | tr -d ' ')" = 2 ] || fail "installs not deduplicated: $all"

# 3. aib start runs a client that is only in an install folder, with its folder on PATH.
BR="$TMP/barrack"; mkdir -p "$BR"; touch "$BR/agent.yaml"
out="$(cd "$BR" && "$AIB" start claude 2>/dev/null)" || fail "aib start claude failed"
echo "$out" | grep -q "^ran claude PATH=$TMP/native:" || fail "client not run from its folder: $out"

# 4. Missing, no terminal to ask in: say how to install, do not prompt, fail.
export AIB_CLIENT_DIRS="$TMP/empty" AIB_INSTALL_CODEX_CMD="echo should-not-run"
if err="$(cd "$BR" && "$AIB" start codex 2>&1 </dev/null)"; then fail "aib start codex succeeded without codex"; fi
echo "$err" | grep -q "should-not-run" || fail "install command not shown: $err"
echo "$err" | grep -q "^should-not-run$" && fail "installer ran without asking"
if "$AIB" install codex </dev/null >/dev/null 2>&1; then fail "aib install succeeded without a terminal"; fi

# 5. Missing, in a terminal: ask; "n" installs nothing, "y" runs the installer.
export AIB_INSTALL_CODEX_CMD="mkdir -p '$TMP/installed' && printf '#!/bin/sh\necho ran codex\n' > '$TMP/installed/codex' && chmod +x '$TMP/installed/codex'"
export AIB_CLIENT_DIRS="$TMP/installed"
printf 'n\n' | AIB_ASSUME_TTY=1 "$AIB" install codex >/dev/null 2>&1 || true
[ ! -e "$TMP/installed/codex" ] || fail "installed after answering n"
printf 'y\n' | AIB_ASSUME_TTY=1 "$AIB" install codex > "$TMP/yes.log" 2>&1 || fail "aib install codex (y) failed: $(cat "$TMP/yes.log")"
[ -x "$TMP/installed/codex" ] || fail "installer did not run after y"
grep -q "installed" "$TMP/yes.log" || fail "no confirmation after install: $(cat "$TMP/yes.log")"
out="$("$AIB" install codex 2>&1)" || fail "aib install on an installed client failed"
echo "$out" | grep -q "$TMP/installed/codex" || fail "installed client not reported: $out"

# 6. aib doctor names each client's path and version and warns about two versions.
fake "$TMP/installed" codex 0.167.0
out="$(PATH="$TMP/brew:$PATH" AIB_CLIENT_DIRS="$TMP/native:$TMP/installed" "$AIB" doctor 2>&1 || true)"
echo "$out" | grep -q "$TMP/brew/claude.*2.1.118" || fail "doctor: PATH's claude missing: $out"
echo "$out" | grep -q "$TMP/native/claude.*2.1.331" || fail "doctor: other claude missing: $out"
echo "$out" | grep -q -i "2 installs" || fail "doctor: no warning about two versions: $out"
echo "$out" | grep -q "$TMP/installed/codex.*0.167.0" || fail "doctor: codex missing: $out"

echo "PASS: claude/codex found off PATH, listed once, started, offered for install (asked first), doctor"
