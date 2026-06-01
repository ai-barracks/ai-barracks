#!/usr/bin/env bash
# Liveness hook wiring: configure_hooks registers SessionStart/End + Pre/Post/Notification/Stop, idempotently.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AIB_BIN="${SCRIPT_DIR}/../bin/aib"
fail() { echo "FAIL: $1"; exit 1; }; pass() { echo "PASS: $1"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SETTINGS="$TMP/settings.json"; echo '{}' > "$SETTINGS"
AIB_SOURCE_ONLY=1 source "$AIB_BIN"; set +e

if ! command -v claude >/dev/null 2>&1; then
  echo "SKIP: claude CLI not installed (configure_hooks gates on it)"; exit 0
fi

AIB_CLAUDE_SETTINGS="$SETTINGS" AIB_GEMINI_SETTINGS="$TMP/gem.json" configure_hooks claude >/dev/null 2>&1
for ev in SessionStart SessionEnd PreToolUse PostToolUse Notification Stop; do
  jq -e --arg e "$ev" '.hooks[$e]' "$SETTINGS" >/dev/null 2>&1 || fail "hook $ev not registered"
done
jq -e '.hooks.PreToolUse[0].hooks[0].command | test("hook event claude PreToolUse")' "$SETTINGS" >/dev/null 2>&1 \
  || fail "PreToolUse command wrong"
# idempotency: re-run must not duplicate
AIB_CLAUDE_SETTINGS="$SETTINGS" AIB_GEMINI_SETTINGS="$TMP/gem.json" configure_hooks claude >/dev/null 2>&1
[ "$(jq '.hooks.SessionStart | length' "$SETTINGS")" = "1" ] || fail "SessionStart duplicated on re-run"
[ "$(jq '.hooks.PreToolUse | length' "$SETTINGS")" = "1" ] || fail "PreToolUse duplicated on re-run"
pass "configure_hooks wires all liveness events + idempotent"
echo "ALL PASS (test_live_hooks_wiring.sh)"
