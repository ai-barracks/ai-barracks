#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cd "$TMP"; touch AGENTS.md
export AIB_LIVE_PID=$$ AIB_LIVE_LSTART="test"
hook() { jq -n --arg event "$1" --arg sid "$2" '{hook_event_name:$event,session_id:$sid}' | "$ROOT/bin/aib" hook native codex; }
hook SessionStart one > first
hook SessionStart two > second
sid1=$(grep 'session file:' first | sed 's/.*sessions\///;s/\.md$//')
sid2=$(grep 'session file:' second | sed 's/.*sessions\///;s/\.md$//')
[ "$sid1" != "$sid2" ]; [ "$(grep -c '| codex-native-' SESSIONS.md)" = 2 ]
printf '\nUser log preserved\n' >> "sessions/$sid1.md"
hook SessionStart one >/dev/null
[ "$(grep -c '| codex-native-' SESSIONS.md)" = 2 ]; grep -q 'User log preserved' "sessions/$sid1.md"
[ "$(hook Stop one)" = '{}' ]
jq -e '.state == "done"' "sessions/.live/$sid1.status" >/dev/null
hook PermissionRequest two
jq -e '.state == "blocked"' "sessions/.live/$sid2.status" >/dev/null
hook SessionEnd one
! grep -qF "| $sid1 |" SESSIONS.md; grep -qF "| $sid2 |" SESSIONS.md
hook SessionStart concurrent-a >/dev/null & p1=$!
hook SessionStart concurrent-b >/dev/null & p2=$!
wait "$p1"; wait "$p2"
[ "$(grep -c '| codex-native-' SESSIONS.md)" = 3 ]
before=$(find sessions -name '*.md' | wc -l)
printf '{broken' | "$ROOT/bin/aib" hook native codex
[ "$before" = "$(find sessions -name '*.md' | wc -l)" ]
hook SessionStart '../../../escape' >/dev/null
[ ! -f "$TMP/escape" ]
export AIB_WRAPPER_SESSION_ID=codex-wrapper-test AIB_WRAPPER_ROOT="$(pwd -P)"
cp "sessions/$sid2.md" sessions/codex-wrapper-test.md
hook SessionStart wrapper > wrapped
grep -q 'sessions/codex-wrapper-test.md' wrapped
hook SessionEnd wrapper
grep -qF '| codex-wrapper-test |' SESSIONS.md
unset AIB_WRAPPER_SESSION_ID AIB_WRAPPER_ROOT
mkdir .codex
printf '{"custom":true,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"user hook"}]}]}}' > .codex/hooks.json
"$ROOT/bin/aib" hooks codex install >/dev/null
"$ROOT/bin/aib" hooks codex install >/dev/null
jq -e '.custom == true and (.hooks.Stop | length) == 2 and .hooks.Stop[0].hooks[0].command == "user hook"' .codex/hooks.json >/dev/null
[ ! -f .codex/config.toml ] # trust is never silently bypassed
mv .codex/hooks.json original; ln -s ../original .codex/hooks.json
if "$ROOT/bin/aib" hooks codex install; then echo 'symlink accepted' >&2; exit 1; fi
echo 'PASS: Codex native identity/concurrency/resume/wrapper/trust preservation'
