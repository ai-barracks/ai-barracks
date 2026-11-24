#!/usr/bin/env bash
# aib behaviour CommandCenter 2 (Swift, PTY daemon) depends on, found 2026-11-24:
# 1. `aib status` (CC2 ⌘K "aib status") with no active session: `grep -c … || echo "0"`
#    printed "0\n0", `[ "$count" -gt 0 ]` failed with "integer expression expected", exit 1.
# 2. The transcript-archive worker was only nohup'd, so it stayed in the terminal's
#    session. CC2 closes a pane by hanging up and, 3 s later, SIGKILLing every process
#    left in that session (HUP-ignoring ones included) — the worker died mid-copy and left
#    state=running, a stale lock and partial .tmp files until the next SessionStart.
#    The worker must run in a session of its own.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AIB_BIN="${SCRIPT_DIR}/../bin/aib"
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. aib status with 0 and 1 active sessions -------------------------------------
BR="$TMP/barrack"; mkdir -p "$BR/sessions"
cp "${SCRIPT_DIR}/../templates/SESSIONS.md" "$BR/SESSIONS.md"
out="$(cd "$BR" && "$AIB_BIN" status 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "status with no session exits $rc: $out"
case "$out" in *"integer expression"*) fail "status with no session: $out" ;; esac
case "$out" in *"Sessions: "*"0 active"*) ;; *) fail "status with no session does not say 0 active: $out" ;; esac
pass "aib status with no active session"

echo "| claude-20261124-120000-abcdef01 | Claude Code | 11-24 12:00 | 11-24 12:00 | test |" >> "$BR/SESSIONS.md"
out="$(cd "$BR" && "$AIB_BIN" status 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "status with one session exits $rc: $out"
case "$out" in *"Sessions: "*"1 active"*) ;; *) fail "status with one session: $out" ;; esac
pass "aib status with one active session"

# --- 2. archive worker in its own session ---------------------------------------------
export AIB_ARCHIVE_DIR="$TMP/archive"
AIB_SOURCE_ONLY=1 source "$AIB_BIN"
set +e
unset AIB_ARCHIVE_SYNC AIB_ARCHIVE_NO_WORKER
STUB="$TMP/stub"; mkdir -p "$STUB"
export AIB_TEST_OUT="$TMP/worker-session"
cat > "$STUB/aib" <<'EOF'
#!/bin/bash
# The worker's child reports whether its parent (the worker) leads its own session.
/usr/bin/python3 -c 'import os; print("leader" if os.getsid(0) == os.getppid() else "member")' > "$AIB_TEST_OUT.tmp"
mv "$AIB_TEST_OUT.tmp" "$AIB_TEST_OUT"
EOF
chmod +x "$STUB/aib"
SCRIPT_DIR="$STUB" _arch_spawn --pending
for _ in $(seq 1 50); do [ -s "$AIB_TEST_OUT" ] && break; sleep 0.1; done
[ -s "$AIB_TEST_OUT" ] || fail "archive worker did not run"
[ "$(cat "$AIB_TEST_OUT")" = leader ] || fail "archive worker shares the caller's session ($(cat "$AIB_TEST_OUT")): a terminal that ends its session on close kills it"
pass "archive worker runs in a session of its own"

echo "ALL PASS: test_commandcenter2"
