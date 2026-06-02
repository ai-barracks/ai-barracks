#!/usr/bin/env bash
# Agent liveness: sidecar writer + alive/dead/unknown reconcile + fold + hook event + cleanup_stale matrix.
# Plan: docs/superpowers/plans/2026-06-01-agent-liveness-aib.md (+ council FINAL integration: lstart, cleanup_stale).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AIB_BIN="${SCRIPT_DIR}/../bin/aib"
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP"; mkdir -p sessions

# Source bin/aib for unit testing (requires AIB_SOURCE_ONLY guard before dispatch).
AIB_SOURCE_ONLY=1 source "$AIB_BIN"
set +e   # bin/aib enables `set -e`; tests rely on explicit `|| fail` checks

# ----- aib_live_write: atomic sidecar + lstart + run_id preservation -----
AIB_LIVE_PID=4242 AIB_LIVE_LSTART="Sun Jun  1 09:00:00 2026" \
  aib_live_write "claude-20260601-1430" "working" "PreToolUse" "tool_activity"
f="sessions/.live/claude-20260601-1430.status"
[ -f "$f" ] || fail "status file not created"
jq empty "$f" 2>/dev/null || fail "status not valid JSON"
[ "$(jq -r .state "$f")" = "working" ] || fail "state mismatch"
[ "$(jq -r .event "$f")" = "PreToolUse" ] || fail "event mismatch"
[ "$(jq -r .pid "$f")" = "4242" ] || fail "pid override not honored"
[ "$(jq -r .lstart "$f")" = "Sun Jun 1 09:00:00 2026" ] || fail "lstart not stored/normalized"
rid1="$(jq -r .run_id "$f")"
AIB_LIVE_PID=4242 aib_live_write "claude-20260601-1430" "blocked" "Notification" "approval_required"
[ "$(jq -r .run_id "$f")" = "$rid1" ] || fail "run_id must be preserved across events"
[ "$(jq -r .state "$f")" = "blocked" ] || fail "state not updated to blocked"
# SessionStart starts a NEW run_id
AIB_LIVE_PID=4242 aib_live_write "claude-20260601-1430" "working" "SessionStart" "session_start"
[ "$(jq -r .run_id "$f")" != "$rid1" ] || fail "SessionStart must start a new run_id"
pass "aib_live_write atomic + lstart + run_id preservation"

# ----- _session_is_alive: alive / dead / reuse / unknown -----
selfp=$$
selfl="$(ps -o lstart= -p "$$" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//')"
AIB_LIVE_PID="$selfp" AIB_LIVE_LSTART="$selfl" aib_live_write "alive1" "working" "PreToolUse" "x"
[ "$(_session_is_alive alive1)" = "alive" ] || fail "self pid + matching lstart should be alive"
AIB_LIVE_PID=999999 AIB_LIVE_LSTART="whatever" aib_live_write "dead1" "working" "x" "x"
[ "$(_session_is_alive dead1)" = "dead" ] || fail "non-existent pid should be dead"
AIB_LIVE_PID="$selfp" AIB_LIVE_LSTART="Mon Jan  1 00:00:00 2000" aib_live_write "reuse1" "working" "x" "x"
[ "$(_session_is_alive reuse1)" = "dead" ] || fail "pid alive but lstart mismatch => dead (PID reuse guard)"
[ "$(_session_is_alive nope)" = "unknown" ] || fail "missing sidecar => unknown"
# fail-safe: kill -0 ok but ps lstart unavailable -> conservative alive
AIB_LIVE_PID="$selfp" AIB_LIVE_LSTART="$selfl" aib_live_write "psfail1" "working" "x" "x"
ps() { command false; }   # stub: ps always fails
[ "$(_session_is_alive psfail1)" = "alive" ] || fail "kill-0 ok + ps fail => conservative alive (fail-safe)"
unset -f ps
pass "_session_is_alive alive/dead/reuse/unknown + ps-fail safe"

# ----- cmd_session_state: fold matrix (kill -0 based, design.md) -----
mk_status() { # mk_status <id> <state> <ts> <pid>
  local d=sessions/.live; mkdir -p "$d"
  jq -n --arg id "$1" --arg s "$2" --argjson ts "$3" --argjson pid "$4" --arg rid "r-$1" \
    '{version:1,session_id:$id,run_id:$rid,state:$s,event:"x",reason:null,source:"claude_hook",confidence:"high",lstart:"",comm:"claude",cwd:".",ts:$ts,pid:$pid}' \
    > "$d/$1.status"
}
NOW="$(date +%s)"
mk_status b1 blocked $((NOW-99999)) $$
[ "$("$AIB_BIN" sessions state b1)" = "blocked" ] || fail "blocked+alive stays blocked regardless of age"
mk_status b2 blocked "$NOW" 999999
[ "$("$AIB_BIN" sessions state b2)" = "crashed" ] || fail "blocked+dead -> crashed"
mk_status w1 working "$NOW" $$
[ "$("$AIB_BIN" sessions state w1)" = "working" ] || fail "working fresh"
mk_status w2 working $((NOW-9999)) $$
[ "$(AIB_LIVE_STALE_WORKING=180 "$AIB_BIN" sessions state w2)" = "working_stale" ] || fail "working old -> working_stale"
mk_status w3 working "$NOW" 999999
[ "$("$AIB_BIN" sessions state w3)" = "interrupted" ] || fail "working+dead -> interrupted"
mk_status d1 done "$NOW" $$
[ "$("$AIB_BIN" sessions state d1)" = "done" ] || fail "done unacked"
jq -n --argjson t "$NOW" '{version:1,acked_run_id:"r-d1",ack_ts:$t}' > sessions/.live/d1.ack
[ "$("$AIB_BIN" sessions state d1)" = "idle" ] || fail "done+ack(ack_ts>=ts) -> idle"
# ack staleness (Codex MAJOR; aib-cc parity): aib reuses one run_id across a session's
# turns, so a LATER done (ts after the ack) in the SAME run_id must NOT be pre-acked.
mk_status d1 done $((NOW+50)) $$
[ "$("$AIB_BIN" sessions state d1)" = "done" ] || fail "later done in same run must not be pre-acked"
[ "$("$AIB_BIN" sessions state nope)" = "none" ] || fail "missing -> none"
pass "cmd_session_state fold matrix"

# ----- cmd_hook_event: EventName -> state for the active session -----
echo "claude-20260601-1430" > sessions/.active
AIB_LIVE_PID=$$ "$AIB_BIN" hook event claude PreToolUse
[ "$("$AIB_BIN" sessions state claude-20260601-1430)" = "working" ] || fail "PreToolUse -> working"
AIB_LIVE_PID=$$ "$AIB_BIN" hook event claude Notification
[ "$("$AIB_BIN" sessions state claude-20260601-1430)" = "blocked" ] || fail "Notification -> blocked"
AIB_LIVE_PID=$$ "$AIB_BIN" hook event claude Stop
[ "$("$AIB_BIN" sessions state claude-20260601-1430)" = "done" ] || fail "Stop -> done"
# SubagentStop must NOT change state (subagent end != session end)
AIB_LIVE_PID=$$ "$AIB_BIN" hook event claude SubagentStop
[ "$("$AIB_BIN" sessions state claude-20260601-1430)" = "done" ] || fail "SubagentStop must not change state"
# no active session -> silent no-op (exit 0)
rm -f sessions/.active
AIB_LIVE_PID=$$ "$AIB_BIN" hook event claude PreToolUse || fail "missing .active must be silent no-op"
pass "cmd_hook_event mapping + SubagentStop ignore + no-active no-op"

# ----- cleanup_stale decision matrix (변종 E regression) -----
THREE_H_AGO="$(date -j -v-3H '+%m-%d %H:%M' 2>/dev/null || date -d '3 hours ago' '+%m-%d %H:%M')"
RECENT="$(date '+%m-%d %H:%M')"
cs_reset() { rm -rf sessions SESSIONS.md; mkdir -p sessions/.live; }
# A) alive sidecar + 3h-old row -> MUST keep (변종 E fix)
cs_reset
echo "| alivesess | Claude | 01-01 | $THREE_H_AGO | t |" > SESSIONS.md
AIB_LIVE_PID="$selfp" AIB_LIVE_LSTART="$selfl" aib_live_write "alivesess" "working" "x" "x"
cleanup_stale
grep -q "alivesess" SESSIONS.md || fail "A: alive session 3h-old MUST be kept (변종E regression)"
# B) dead sidecar + recent row -> reap immediately
cs_reset
echo "| deadsess | Claude | 01-01 | $RECENT | t |" > SESSIONS.md
AIB_LIVE_PID=999999 AIB_LIVE_LSTART="x" aib_live_write "deadsess" "working" "x" "x"
cleanup_stale
grep -q "deadsess" SESSIONS.md && fail "B: dead session must be reaped immediately even if recent"
# C) no sidecar + 3h-old -> legacy time rule reaps
cs_reset
echo "| legacysess | Claude | 01-01 | $THREE_H_AGO | t |" > SESSIONS.md
cleanup_stale
grep -q "legacysess" SESSIONS.md && fail "C: no-sidecar 3h-old must reap by time rule"
# D) no sidecar + 3h-old + strict -> keep
cs_reset
echo "| legacy2 | Claude | 01-01 | $THREE_H_AGO | t |" > SESSIONS.md
AIB_CLEANUP_REQUIRE_LIVENESS=1 cleanup_stale
grep -q "legacy2" SESSIONS.md || fail "D: strict mode must keep no-sidecar legacy row"
pass "cleanup_stale matrix: alive-keep / dead-reap / legacy-time / strict-keep"

# regression (Codex critical): cleanup_stale must SURVIVE `set -e` when age not exceeded / parse fails.
# The `[ ] && [ ] && age_exceeded=1` statement returns 1 and kills hook_start under set -e.
( set -e; cs_reset; echo "| recentsess | C | 01-01 | $RECENT | t |" > SESSIONS.md; cleanup_stale ) \
  || fail "REGRESSION: cleanup_stale crashed under set -e"
pass "cleanup_stale survives set -e"

# ----- ensure_live_gitignore -----
cs_reset; touch .gitignore
ensure_live_gitignore
grep -qx 'sessions/.live/' .gitignore || fail "ensure_live_gitignore must add sessions/.live/"
ensure_live_gitignore
[ "$(grep -c 'sessions/.live/' .gitignore)" = "1" ] || fail "ensure_live_gitignore must be idempotent"
pass "ensure_live_gitignore add + idempotent"

# ----- hardening (Codex review): never crash hook/CLI -----
( set -eu; aib_live_write ) || fail "aib_live_write must no-op on missing args (set -u)"
cs_reset; echo "{ broken json" > sessions/.live/corrupt.status
[ "$("$AIB_BIN" sessions state corrupt)" = "unknown" ] || fail "corrupt sidecar -> unknown (no crash)"
pass "hardening: missing-args no-op + corrupt-sidecar -> unknown"

# ----- AIB-005: SCRIPT_DIR/TEMPLATE_DIR must resolve when sourced from any cwd -----
# We are already inside `cd "$TMP"` and have sourced bin/aib at the top.
# If SCRIPT_DIR used `$0` it would resolve relative to the test script, then
# `$SCRIPT_DIR/../templates` would not point at the real templates dir.
[ -n "${SCRIPT_DIR:-}" ] || fail "SCRIPT_DIR unset after sourcing bin/aib"
[ -n "${TEMPLATE_DIR:-}" ] || fail "TEMPLATE_DIR unset after sourcing bin/aib"
[ -d "$TEMPLATE_DIR" ] || fail "TEMPLATE_DIR ($TEMPLATE_DIR) not a directory after source-from-other-cwd"
[ -f "$TEMPLATE_DIR/session-context.md" ] || fail "TEMPLATE_DIR/session-context.md not found ($TEMPLATE_DIR)"
pass "AIB-005: source bin/aib resolves TEMPLATE_DIR after cwd change"

# ----- AIB-001: make_session_id is collision-resistant within the same minute -----
sid1="$(make_session_id claude)"
sid2="$(make_session_id claude)"
[ -n "$sid1" ] && [ -n "$sid2" ] || fail "AIB-001: make_session_id returned empty"
[ "$sid1" != "$sid2" ] || fail "AIB-001: two immediate calls produced identical IDs ($sid1)"
# Readable client-prefixed format: claude-YYYYMMDD-HHMMSS-<entropy>
case "$sid1" in
  claude-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-*) ;;
  *) fail "AIB-001: id missing client-YYYYMMDD-HHMMSS-<entropy> prefix: $sid1" ;;
esac
# Filename-safe: no slashes, spaces, or shell-special chars
case "$sid1" in
  *[!A-Za-z0-9._-]*) fail "AIB-001: id contains non-filename-safe chars: $sid1" ;;
esac
# Different clients keep their prefix
sid_codex="$(make_session_id codex)"
case "$sid_codex" in
  codex-*) ;;
  *) fail "AIB-001: codex prefix lost: $sid_codex" ;;
esac
# A burst of IDs must all be unique (no collisions even when called rapidly)
burst="$(for _ in 1 2 3 4 5 6 7 8; do make_session_id claude; done | sort -u | wc -l | tr -d ' ')"
[ "$burst" = "8" ] || fail "AIB-001: burst of 8 ids collapsed to $burst unique values"
pass "AIB-001: make_session_id collision-resistant + readable + filename-safe"

# ----- AIB-001: entropy-source failures fall back cleanly under `set -euo pipefail` -----
# Run in a clean sub-bash so stubs do not leak into the rest of the test file.
sid_uuid_fail="$(bash -c '
  AIB_SOURCE_ONLY=1 source "'"$AIB_BIN"'"
  set -euo pipefail
  uuidgen() { return 1; }
  make_session_id claude
')" || fail "AIB-001: failing uuidgen aborted make_session_id under set -euo pipefail"
case "$sid_uuid_fail" in
  claude-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-????????) ;;
  *) fail "AIB-001: uuidgen-fallback id malformed: $sid_uuid_fail" ;;
esac
sid_both_fail="$(bash -c '
  AIB_SOURCE_ONLY=1 source "'"$AIB_BIN"'"
  set -euo pipefail
  uuidgen() { return 1; }
  od() { return 1; }
  make_session_id claude
')" || fail "AIB-001: failing uuidgen+od aborted make_session_id under set -euo pipefail"
case "$sid_both_fail" in
  claude-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-????????) ;;
  *) fail "AIB-001: RANDOM-fallback id malformed: $sid_both_fail" ;;
esac
pass "AIB-001: make_session_id falls back when entropy sources fail under set -euo pipefail"

# ----- AIB-001 integration: two hook starts create distinct session files -----
# Use a fresh barrack dir so we don't perturb the cleanup_stale fixtures above.
HB="$(mktemp -d)"
(
  cd "$HB"
  cp "$TEMPLATE_DIR/SESSIONS.md" SESSIONS.md
  mkdir -p sessions
  AIB_LIVE_PID=$$ "$AIB_BIN" hook start claude >/dev/null
  s1="$(cat sessions/.active)"
  AIB_LIVE_PID=$$ "$AIB_BIN" hook start claude >/dev/null
  s2="$(cat sessions/.active)"
  [ "$s1" != "$s2" ] || { echo "FAIL: two hook starts produced same session_id ($s1)"; exit 1; }
  [ -f "sessions/${s1}.md" ] || { echo "FAIL: first session context file missing: sessions/${s1}.md"; exit 1; }
  [ -f "sessions/${s2}.md" ] || { echo "FAIL: second session context file missing: sessions/${s2}.md"; exit 1; }
  # Live sidecars must be distinct per session and self-identify with the right session_id.
  [ -f "sessions/.live/${s1}.status" ] || { echo "FAIL: first live sidecar missing: sessions/.live/${s1}.status"; exit 1; }
  [ -f "sessions/.live/${s2}.status" ] || { echo "FAIL: second live sidecar missing: sessions/.live/${s2}.status"; exit 1; }
  [ "$(jq -r .session_id "sessions/.live/${s1}.status")" = "$s1" ] || { echo "FAIL: sidecar session_id mismatch for $s1"; exit 1; }
  [ "$(jq -r .session_id "sessions/.live/${s2}.status")" = "$s2" ] || { echo "FAIL: sidecar session_id mismatch for $s2"; exit 1; }
  # SESSIONS.md must have exactly one row per session_id (distinct registry rows).
  n1="$(grep -c "^| ${s1} " SESSIONS.md)"
  n2="$(grep -c "^| ${s2} " SESSIONS.md)"
  [ "$n1" = "1" ] || { echo "FAIL: expected exactly 1 SESSIONS.md row for $s1, got $n1"; exit 1; }
  [ "$n2" = "1" ] || { echo "FAIL: expected exactly 1 SESSIONS.md row for $s2, got $n2"; exit 1; }
) || fail "AIB-001 integration: distinct session files per hook start"
rm -rf "$HB"
pass "AIB-001 integration: back-to-back hook starts produce distinct session files"

echo "ALL PASS (test_live_state.sh phase 1-6)"
