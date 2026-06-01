#!/usr/bin/env bash
# Orphan/stuck-session reaper (변종 B + 변종 G).
# - 변종 G: liveness sidecar (.live/<id>.status) never GC'd → dead sidecars accumulate.
# - 변종 B: a session that died abnormally leaves sessions/<id>.md stuck at Status: active.
# Repro of the two sessions observed 2026-06-01: 2326 (dead sidecar) + 2320 (no sidecar, stuck-active).
# Design + adversarial council review: wiki/topics/AIB-Hook-Stale-Cleanup-Bug.md (변종 G).
#
# Safety contract (council adversarial review, v1.3.2):
#   - reap_dead_sidecars (Pass A): runs AUTO (cleanup_stale) + manual. Only confirmed-dead
#     (kill -0 / lstart reuse) sidecars; removes sidecar + marks its .md interrupted.
#   - reap_stuck_md (Pass B): MANUAL-only (`aib sessions gc`). Time-based on a .md WITHOUT a
#     sidecar — never auto, because a missing sidecar is a weak liveness proxy (false-reap risk).
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

mk_session_md() { # mk_session_md <sid> <status:active|completed>
  cat > "sessions/${1}.md" <<EOF
<!-- header -->
# Session: ${1}
- **Started**: 2026-05-31 23:20
- **Ended**: (active)
- **Status**: ${2}
- **Task**: t
EOF
}
status_of() { grep -m1 '^- \*\*Status\*\*:' "sessions/$1.md" | sed 's/.*: //'; }
reset() { rm -rf sessions SESSIONS.md; mkdir -p sessions/.live; }

# ---------- Pass A (auto-safe): dead sidecar reaped + stuck-active .md interrupted (2326) ----------
reset
AIB_LIVE_PID=999999 AIB_LIVE_LSTART="x" aib_live_write "claude-dead" "blocked" "Notification" "approval_required"
mk_session_md "claude-dead" active
reap_dead_sidecars
[ ! -f sessions/.live/claude-dead.status ] || fail "G: dead sidecar must be removed"
[ "$(status_of claude-dead)" = "interrupted" ] || fail "G: dead session .md must be interrupted"
grep -q '^- \*\*Ended\*\*:.*(stale)' sessions/claude-dead.md || fail "G: Ended must be (stale)"
pass "변종 G: dead sidecar reaped + .md interrupted (Pass A, 2326)"

# ---------- Pass A LIVE PROTECTION (P0) ----------
reset
AIB_LIVE_PID="$selfp" AIB_LIVE_LSTART="$selfl" aib_live_write "claude-live" "working" "PreToolUse" "x"
mk_session_md "claude-live" active
reap_dead_sidecars
[ -f sessions/.live/claude-live.status ] || fail "P0: live sidecar must NEVER be removed"
[ "$(status_of claude-live)" = "active" ] || fail "P0: live .md must stay active"
pass "P0: live session never reaped (Pass A)"

# ---------- Pass A must NOT flip a no-sidecar stuck .md (that is Pass B's MANUAL job) ----------
reset
mk_session_md "claude-old" active; touch -t 202601010000 sessions/claude-old.md
reap_dead_sidecars
[ "$(status_of claude-old)" = "active" ] || fail "Pass A must NOT touch no-sidecar .md"
pass "Pass A leaves no-sidecar stuck .md alone"

# ---------- cleanup_stale AUTO path must NOT run Pass B (no auto false-reap of no-sidecar .md) ----------
reset
mk_session_md "claude-auto" active; touch -t 202601010000 sessions/claude-auto.md
printf '\n' > SESSIONS.md
cleanup_stale
[ "$(status_of claude-auto)" = "active" ] || fail "cleanup_stale (auto) must NOT flip no-sidecar .md — Pass B is manual-only"
pass "cleanup_stale auto path runs Pass A only (no Pass B)"

# ---------- Pass B (MANUAL): old no-sidecar stuck-active reaped (2320) ----------
reset
mk_session_md "claude-2320" active; touch -t 202601010000 sessions/claude-2320.md
reap_stuck_md
[ "$(status_of claude-2320)" = "interrupted" ] || fail "B: manual Pass B must reap old no-sidecar stuck .md"
pass "변종 B: manual reap_stuck_md reaps old no-sidecar (2320)"

# ---------- Pass B guard: fresh no-sidecar kept ----------
reset
mk_session_md "claude-fresh" active
reap_stuck_md
[ "$(status_of claude-fresh)" = "active" ] || fail "B-guard: fresh no-sidecar must be kept"
pass "변종 B guard: fresh no-sidecar kept"

# ---------- .active session protected (Pass B), incl. CRLF/whitespace normalization ----------
reset
mk_session_md "claude-current" active; touch -t 202601010000 sessions/claude-current.md
printf 'claude-current\r\n' > sessions/.active     # CRLF + trailing newline
reap_stuck_md
[ "$(status_of claude-current)" = "active" ] || fail "active session must be protected even with CRLF .active"
pass "current .active protected + CRLF/whitespace normalized"

# ---------- done + dead sidecar: GC the sidecar, leave completed .md alone (Pass A) ----------
reset
AIB_LIVE_PID=999999 AIB_LIVE_LSTART="x" aib_live_write "claude-done" "done" "Stop" "turn_complete"
mk_session_md "claude-done" completed
reap_dead_sidecars
[ ! -f sessions/.live/claude-done.status ] || fail "done+dead: stale sidecar must be GC'd"
[ "$(status_of claude-done)" = "completed" ] || fail "done+dead: completed .md untouched"
pass "done+dead sidecar GC'd, completed .md untouched"

# ---------- AIB_REAP_ORPHAN_AGE non-numeric → fallback to default, no abort ----------
reset
mk_session_md "claude-bad" active; touch -t 202601010000 sessions/claude-bad.md
( set -e; AIB_REAP_ORPHAN_AGE=abc reap_stuck_md ) || fail "grace=abc must not abort under set -e"
[ "$(status_of claude-bad)" = "interrupted" ] || fail "grace=abc must fall back to default and reap old"
pass "AIB_REAP_ORPHAN_AGE=abc validated (fallback, no abort)"

# ---------- portable .md flip works (sed must not be `sed -i ''` BSD-only) ----------
# A flip done by reap_dead_sidecars must leave a well-formed file (no .tmp leftovers).
reset
AIB_LIVE_PID=999999 AIB_LIVE_LSTART="x" aib_live_write "claude-port" "working" "x" "x"
mk_session_md "claude-port" active
reap_dead_sidecars
[ "$(status_of claude-port)" = "interrupted" ] || fail "portable flip: .md must be interrupted"
[ -z "$(ls sessions/claude-port.md.* 2>/dev/null)" ] || fail "portable flip: no .tmp leftover"
pass "portable .md flip (tmp+mv), no leftover"

# ---------- CLI strict arg handling ----------
reset
AIB_LIVE_PID=999999 AIB_LIVE_LSTART="x" aib_live_write "claude-cli" "working" "x" "x"
mk_session_md "claude-cli" active
"$AIB_BIN" sessions gc --dryrun  >/dev/null 2>&1 && fail "gc --dryrun (typo) must be rejected"
"$AIB_BIN" sessions gc --dry-run extra >/dev/null 2>&1 && fail "gc with extra arg must be rejected"
[ -f sessions/.live/claude-cli.status ] || fail "rejected gc invocations must not reap"
"$AIB_BIN" sessions gc --dry-run >/dev/null 2>&1
[ -f sessions/.live/claude-cli.status ] || fail "dry-run must not reap"
[ "$(status_of claude-cli)" = "active" ] || fail "dry-run must not change .md"
pass "aib sessions gc strict args + dry-run non-destructive"

# ---------- CLI: aib sessions gc performs the reap (Pass A + B) ----------
"$AIB_BIN" sessions gc >/dev/null 2>&1
[ ! -f sessions/.live/claude-cli.status ] || fail "gc must remove dead sidecar"
[ "$(status_of claude-cli)" = "interrupted" ] || fail "gc must mark dead-sidecar .md interrupted"
pass "aib sessions gc reaps (Pass A + Pass B)"

# ---------- reapers survive set -e WITH work (loops exercised) ----------
(
  set -e
  reset
  echo "claude-keep" > sessions/.active; mk_session_md "claude-keep" active
  AIB_LIVE_PID=999999 AIB_LIVE_LSTART="x" aib_live_write "claude-x" "working" "x" "x"; mk_session_md "claude-x" active
  mk_session_md "claude-nosc" active; touch -t 202601010000 sessions/claude-nosc.md
  reap_dead_sidecars
  reap_stuck_md
) || fail "REGRESSION: reapers crashed under set -e (with work)"
pass "reapers survive set -e with work"

echo "ALL PASS (test_live_reaper.sh)"
