#!/usr/bin/env bash
# Orphan/stuck-session reaper (변종 B + 변종 G).
# - 변종 G: liveness sidecar (.live/<id>.status) never GC'd → dead sidecars accumulate.
# - 변종 B: a session that died abnormally leaves sessions/<id>.md stuck at Status: active.
# Repro of the two sessions observed 2026-06-01: 2326 (dead sidecar) + 2320 (no sidecar, stuck-active).
# wiki/topics/AIB-Hook-Stale-Cleanup-Bug.md (변종 G fix 방향).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AIB_BIN="${SCRIPT_DIR}/../bin/aib"
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP"; mkdir -p sessions/.live

AIB_SOURCE_ONLY=1 source "$AIB_BIN"
set +e   # bin/aib enables `set -e`; tests rely on explicit `|| fail`

selfp=$$
selfl="$(ps -o lstart= -p "$$" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//')"

# Write a minimal session .md with the exact header lines the reaper's sed targets.
mk_session_md() { # mk_session_md <sid> <status:active|completed>
  local sid="$1" status="$2"
  cat > "sessions/${sid}.md" <<EOF
<!-- header -->
# Session: ${sid}
- **Started**: 2026-05-31 23:20
- **Ended**: (active)
- **Status**: ${status}
- **Task**: t
EOF
}
status_of() { grep -m1 '^- \*\*Status\*\*:' "sessions/$1.md" | sed 's/.*: //'; }
reset() { rm -rf sessions; mkdir -p sessions/.live; }

# ---------- 변종 G: dead sidecar reaped + its stuck-active .md marked interrupted (2326 repro) ----------
reset
AIB_LIVE_PID=999999 AIB_LIVE_LSTART="x" aib_live_write "claude-dead" "blocked" "Notification" "approval_required"
mk_session_md "claude-dead" active
[ -f sessions/.live/claude-dead.status ] || fail "G-setup: dead sidecar should exist"
reap_orphan_sessions
[ ! -f sessions/.live/claude-dead.status ] || fail "G: dead sidecar must be removed"
[ "$(status_of claude-dead)" = "interrupted" ] || fail "G: dead session .md must be marked interrupted"
grep -q '^- \*\*Ended\*\*:.*(stale)' sessions/claude-dead.md || fail "G: Ended must be stamped (stale)"
pass "변종 G: dead sidecar reaped + .md interrupted (2326)"

# ---------- LIVE PROTECTION (P0): alive sidecar + active .md must be untouched ----------
reset
AIB_LIVE_PID="$selfp" AIB_LIVE_LSTART="$selfl" aib_live_write "claude-live" "working" "PreToolUse" "x"
mk_session_md "claude-live" active
reap_orphan_sessions
[ -f sessions/.live/claude-live.status ] || fail "P0: live sidecar must NEVER be removed"
[ "$(status_of claude-live)" = "active" ] || fail "P0: live session .md must stay active"
pass "P0: live session never reaped"

# ---------- 변종 B: stuck-active .md with NO sidecar, old → reaped by time fallback (2320 repro) ----------
reset
mk_session_md "claude-old" active
touch -t 202601010000 sessions/claude-old.md      # mtime far in the past
reap_orphan_sessions
[ "$(status_of claude-old)" = "interrupted" ] || fail "B: old no-sidecar active .md must be marked interrupted"
pass "변종 B: old no-sidecar stuck-active reaped (2320)"

# ---------- 변종 B guard: FRESH no-sidecar active .md must be kept (just-started, sidecar lag) ----------
reset
mk_session_md "claude-fresh" active                # mtime = now
reap_orphan_sessions
[ "$(status_of claude-fresh)" = "active" ] || fail "B-guard: fresh no-sidecar active .md must be kept"
pass "변종 B guard: fresh no-sidecar kept"

# ---------- current .active session protected even with no/old evidence ----------
reset
mk_session_md "claude-current" active
touch -t 202601010000 sessions/claude-current.md   # old, but it IS the active session
echo "claude-current" > sessions/.active
reap_orphan_sessions
[ "$(status_of claude-current)" = "active" ] || fail "active-guard: current session must never be reaped"
pass "current .active session protected"

# ---------- done + dead sidecar: GC the sidecar, leave completed .md alone ----------
reset
AIB_LIVE_PID=999999 AIB_LIVE_LSTART="x" aib_live_write "claude-done" "done" "Stop" "turn_complete"
mk_session_md "claude-done" completed
reap_orphan_sessions
[ ! -f sessions/.live/claude-done.status ] || fail "done+dead: stale sidecar must be GC'd"
[ "$(status_of claude-done)" = "completed" ] || fail "done+dead: completed .md must be untouched"
pass "done+dead sidecar GC'd, completed .md untouched"

# ---------- CLI: aib sessions gc --dry-run changes NOTHING ----------
reset
AIB_LIVE_PID=999999 AIB_LIVE_LSTART="x" aib_live_write "claude-dry" "working" "x" "x"
mk_session_md "claude-dry" active
"$AIB_BIN" sessions gc --dry-run >/dev/null 2>&1
[ -f sessions/.live/claude-dry.status ] || fail "dry-run: must NOT remove sidecar"
[ "$(status_of claude-dry)" = "active" ] || fail "dry-run: must NOT change .md"
pass "aib sessions gc --dry-run is non-destructive"

# ---------- CLI: aib sessions gc performs the reap ----------
"$AIB_BIN" sessions gc >/dev/null 2>&1
[ ! -f sessions/.live/claude-dry.status ] || fail "gc: must remove dead sidecar"
[ "$(status_of claude-dry)" = "interrupted" ] || fail "gc: must mark stuck-active .md interrupted"
pass "aib sessions gc reaps"

# ---------- reaper survives set -e WITH work (loops exercised; skip-guards must not abort) ----------
# Regression for the codebase's `[ ] && ...` set -e hazard: a non-active session whose
# sid != active_id, a dead sidecar, and a no-sidecar .md must all be traversed without crashing.
(
  set -e
  reset
  echo "claude-keep" > sessions/.active
  mk_session_md "claude-keep" active                                   # the active one (skipped)
  AIB_LIVE_PID=999999 AIB_LIVE_LSTART="x" aib_live_write "claude-x" "working" "x" "x"  # dead sidecar
  mk_session_md "claude-x" active
  mk_session_md "claude-nosc" active; touch -t 202601010000 sessions/claude-nosc.md    # old, no sidecar
  reap_orphan_sessions
) || fail "REGRESSION: reap_orphan_sessions crashed under set -e (with work)"
# and verify it actually did the work in that set -e subshell's filesystem effects
reset
echo "claude-keep" > sessions/.active
mk_session_md "claude-keep" active
AIB_LIVE_PID=999999 AIB_LIVE_LSTART="x" aib_live_write "claude-x" "working" "x" "x"
mk_session_md "claude-x" active
( set -e; reap_orphan_sessions )
[ "$(status_of claude-keep)" = "active" ]      || fail "set -e: active session must be kept"
[ "$(status_of claude-x)" = "interrupted" ]    || fail "set -e: dead-sidecar session must be reaped"
[ ! -f sessions/.live/claude-x.status ]        || fail "set -e: dead sidecar must be removed"
pass "reap_orphan_sessions survives set -e and does its work"

echo "ALL PASS (test_live_reaper.sh)"
