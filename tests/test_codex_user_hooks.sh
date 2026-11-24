#!/usr/bin/env bash
# Codex hooks user-level, like Claude's (2026-11-25: Codex agents reported no
# state and "정리하고 닫기" could not close them unless each barrack had run
# `aib hooks codex install` and its hooks were trusted). One install in
# $CODEX_HOME/hooks.json and one trust in Codex /hooks cover every barrack.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AIB="$ROOT/bin/aib"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v jq)")" HOME="$TMP/home"
export AIB_CLAUDE_SETTINGS="$TMP/claude-settings.json" AIB_CLIENT_DIRS="$TMP/none"
unset CODEX_HOME AIB_CODEX_HOOKS
mkdir -p "$HOME/.codex"
HOOKS="$HOME/.codex/hooks.json"
EVENTS="SessionStart SessionEnd UserPromptSubmit PreToolUse PostToolUse PermissionRequest Stop Interrupt"
has_all() { for ev in $EVENTS; do jq -e --arg e "$ev" '[.hooks[$e][]?.hooks[]?.command] | any(. == "aib hook native codex")' "$1" >/dev/null || return 1; done; }

# 1. --user: every event, the user's own hooks kept, nothing added twice.
printf '{"custom":1,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"user hook"}]}]}}' > "$HOOKS"
"$AIB" hooks codex install --user >/dev/null 2>&1
has_all "$HOOKS" || fail "not every event has aib's hook: $(cat "$HOOKS")"
jq -e '.custom == 1 and (.hooks.Stop | length) == 2 and .hooks.Stop[0].hooks[0].command == "user hook"' "$HOOKS" >/dev/null \
    || fail "the user's own hooks were not kept"
before="$(shasum "$HOOKS")"
out="$("$AIB" hooks codex install --user 2>&1)"
[ "$before" = "$(shasum "$HOOKS")" ] || fail "second install rewrote the file"
echo "$out" | grep -q "already set" || fail "second install not reported as already set: $out"
[ ! -e "$HOME/.codex/config.toml" ] || fail "trust settings touched"

# 2. CODEX_HOME is where Codex looks.
CODEX_HOME="$TMP/codex-home" "$AIB" hooks codex install --user >/dev/null 2>&1
has_all "$TMP/codex-home/hooks.json" || fail "CODEX_HOME ignored"

# 3. Never through a symlink (a dotfiles-managed file stays as it is).
mkdir -p "$TMP/linked/.codex"; echo '{"hooks":{}}' > "$TMP/dotfile.json"; ln -s "$TMP/dotfile.json" "$TMP/linked/.codex/hooks.json"
if HOME="$TMP/linked" "$AIB" hooks codex install --user >/dev/null 2>&1; then fail "wrote through a symlink"; fi
[ "$(cat "$TMP/dotfile.json")" = '{"hooks":{}}' ] || fail "symlink target changed"

# 4. aib init with Codex installed sets the hooks up; AIB_CODEX_HOOKS=0 opts out;
#    a missing Claude is not asked about without a terminal.
mkdir -p "$TMP/bin"; printf '#!/bin/sh\necho "0.167.0"\n' > "$TMP/bin/codex"; chmod +x "$TMP/bin/codex"
export AIB_CLIENT_DIRS="$TMP/bin"
rm -f "$HOOKS"
out="$("$AIB" init "$TMP/new-barrack" 2>&1 </dev/null)" || fail "aib init failed: $out"
has_all "$HOOKS" || fail "aib init did not install Codex hooks: $out"
echo "$out" | grep -q "/hooks" || fail "aib init did not say to trust the hooks in /hooks"
echo "$out" | grep -q "aib install claude" || fail "aib init did not say how to install the missing Claude: $out"
rm -f "$HOOKS"
AIB_CODEX_HOOKS=0 "$AIB" init "$TMP/opt-out" >/dev/null 2>&1 </dev/null
[ ! -e "$HOOKS" ] || fail "AIB_CODEX_HOOKS=0 still installed Codex hooks"

# 5. aib sync brings an older barrack's machine up to date (not in --dry-run).
( cd "$TMP/new-barrack" && "$AIB" sync --dry-run >/dev/null 2>&1 )
[ ! -e "$HOOKS" ] || fail "sync --dry-run installed hooks"
( cd "$TMP/new-barrack" && "$AIB" sync >/dev/null 2>&1 )
has_all "$HOOKS" || fail "aib sync did not install Codex hooks"

echo "PASS: Codex user-level hooks (every event, kept, once, CODEX_HOME, no symlink, init/sync, opt-out)"
