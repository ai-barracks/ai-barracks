#!/usr/bin/env bash
# Hooks act only in a barrack (2026-11-25: the user-level Claude hooks left
# SESSIONS.md and sessions/ in ~/Develop/ai-barracks and other plain repos).
# A barrack is a folder with agent.yaml, or one in the aib registry.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AIB="$ROOT/bin/aib"
TMP="$(mktemp -d)"; trap 'kill "${HOLDER:-0}" 2>/dev/null; rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
sleep 600 & HOLDER=$!
export AIB_LIVE_PID="$HOLDER" AIB_LIVE_LSTART="test" AIB_REGISTRY="$TMP/registry.json"
echo '[]' > "$AIB_REGISTRY"

untouched() { [ ! -e "$1/SESSIONS.md" ] && [ ! -e "$1/sessions" ]; }

# A plain repo (it even has AGENTS.md, as many Codex repos do).
PLAIN="$TMP/plain"; mkdir -p "$PLAIN"; touch "$PLAIN/AGENTS.md" "$PLAIN/CLAUDE.md"
(
    cd "$PLAIN"
    out="$(echo '{}' | "$AIB" hook start claude)"
    [ -z "$out" ] || fail "hook start printed in a plain repo: $out"
    echo '{}' | "$AIB" hook event claude PreToolUse
    echo '{}' | "$AIB" hook event claude Stop
    echo '{}' | "$AIB" hook end claude >/dev/null 2>&1 || true
    native() { jq -n --arg e "$1" '{hook_event_name:$e,session_id:"n1"}' | "$AIB" hook native codex; }
    native SessionStart >/dev/null
    [ "$(native Stop)" = '{}' ] || fail "Codex Stop must still answer {} outside a barrack"
)
untouched "$PLAIN" || fail "hooks wrote session files into a plain repo: $(ls -A "$PLAIN")"

# A barrack by agent.yaml: hooks work.
BARRACK="$TMP/barrack"; mkdir -p "$BARRACK"; touch "$BARRACK/agent.yaml" "$BARRACK/AGENTS.md"
( cd "$BARRACK" && echo '{}' | "$AIB" hook start claude >/dev/null )
[ -f "$BARRACK/SESSIONS.md" ] && [ -s "$BARRACK/sessions/.active" ] || fail "hook start did nothing in a barrack"
( cd "$BARRACK" && jq -n '{hook_event_name:"SessionStart",session_id:"n2"}' | "$AIB" hook native codex >/dev/null )
ls "$BARRACK"/sessions/codex-native-*.md >/dev/null 2>&1 || fail "Codex hook did nothing in a barrack"

# A registered barrack without agent.yaml (made before agent.yaml existed).
OLD="$TMP/old"; mkdir -p "$OLD"
jq -n --arg p "$OLD" '[{path:$p,name:"old"}]' > "$AIB_REGISTRY"
( cd "$OLD" && echo '{}' | "$AIB" hook start claude >/dev/null )
[ -f "$OLD/SESSIONS.md" ] || fail "hook start ignored a registered barrack"

echo "PASS: hooks act only in a barrack (agent.yaml or registered)"
