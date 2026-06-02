#!/usr/bin/env bash
#
# test_council_hardening.sh — AIB-003 / Batch P0-council regressions.
#
# Covers:
#   1. False-success prevention: debate mode with <2 valid responses must NOT
#      run synthesis; manifest status must reflect the failure.
#   2. Claude hook/cwd isolation: call_claude must run from a neutral cwd
#      (not the caller barrack) and pass --setting-sources project,local so
#      user-level hooks cannot mutate the caller's sessions/.active sentinel.
#   3. Orphan process cleanup: when a slow agent stub spawns a long-lived
#      child, the grace-period kill must collect the whole process tree.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# ── Common stub: neutralise the macOS keychain quota probe. ──
make_security_stub() {
    local dir="$1"
    cat > "$dir/security" <<'SH'
#!/usr/bin/env bash
exit 1
SH
    chmod +x "$dir/security"
}

# ────────────────────────────────────────────────────────────
# Test 1: False-success prevention
# ────────────────────────────────────────────────────────────
test_false_success_prevention() {
    local td="$TMP_ROOT/t1"
    mkdir -p "$td"
    export COUNCIL_STUB_CALLS="$td/calls.log"
    : > "$COUNCIL_STUB_CALLS"

    # Claude stub: returns a valid >20-word response.
    cat > "$td/claude" <<'SH'
#!/usr/bin/env bash
echo "CLAUDE_ARGS:$*" >> "${COUNCIL_STUB_CALLS:?}"
echo "Claude stub provides a thorough valid response with sufficient words exceeding the twenty word minimum threshold so council response validation succeeds for this regression test."
SH

    # Codex stub: fails — no stdout, exit non-zero. Council should treat
    # this round as having only 1 valid response and refuse to synthesise.
    cat > "$td/codex" <<'SH'
#!/usr/bin/env bash
echo "CODEX_ARGS:$*" >> "${COUNCIL_STUB_CALLS:?}"
exit 1
SH

    make_security_stub "$td"
    chmod +x "$td/claude" "$td/codex"

    local rc=0
    PATH="$td:$PATH" \
    AIB_COUNCIL_MAX_RETRIES=0 \
    AIB_COUNCIL_RETRY_DELAY=0 \
    "$ROOT/scripts/council.sh" -r 1 --consensus 0 --grace 0 --json \
        "smoke test topic" \
        > "$td/out.json" 2> "$td/err.log" || rc=$?

    if [[ $rc -eq 0 ]]; then
        echo "--- council stderr ---" >&2
        cat "$td/err.log" >&2
        fail "[t1] council exited 0 but only one agent returned a valid response"
    fi

    local session_dir
    session_dir=$(grep -oE '/tmp/council/[0-9_]+' "$td/err.log" | head -1)
    [[ -z "$session_dir" ]] && fail "[t1] could not locate session dir from stderr"
    [[ -f "$session_dir/manifest.json" ]] || fail "[t1] no manifest at $session_dir"

    local status
    status=$(jq -r '.status' "$session_dir/manifest.json")
    [[ "$status" == "insufficient_valid_agents" ]] \
        || fail "[t1] expected manifest.status=insufficient_valid_agents, got: $status"

    local synthesis
    synthesis=$(jq -r '.final_synthesis' "$session_dir/manifest.json")
    [[ "$synthesis" == "null" ]] \
        || fail "[t1] final_synthesis should be null when council bails early, got: ${synthesis:0:80}"

    # Sanity: also ensure manifest did NOT get a 'completed' status.
    if grep -q '"status": "completed"' "$session_dir/manifest.json"; then
        fail "[t1] manifest reports completed status despite single-agent round"
    fi

    rm -rf "$session_dir"
    unset COUNCIL_STUB_CALLS
    echo "  PASS  t1: false-success prevention"
}

# ────────────────────────────────────────────────────────────
# Test 2: Claude hook/cwd isolation
# ────────────────────────────────────────────────────────────
test_claude_cwd_isolation() {
    local td="$TMP_ROOT/t2"
    mkdir -p "$td"

    # Caller "barrack" with sessions/.active sentinel.
    local barrack="$td/barrack"
    mkdir -p "$barrack/sessions"
    touch "$barrack/sessions/.active"

    export COUNCIL_STUB_CALLS="$td/calls.log"
    : > "$COUNCIL_STUB_CALLS"
    export BARRACK_DIR="$barrack"

    # Claude stub: records its cwd, and (simulating user-hook contamination)
    # removes sessions/.active in its own cwd. If council passed our cwd
    # (the barrack) through, the sentinel disappears.
    cat > "$td/claude" <<'SH'
#!/usr/bin/env bash
echo "CLAUDE_ARGS:$*" >> "${COUNCIL_STUB_CALLS:?}"
echo "CLAUDE_CWD:$PWD" >> "${COUNCIL_STUB_CALLS:?}"
# Emulate the hook side-effect we are trying to keep out of the barrack.
[[ -f "sessions/.active" ]] && rm -f "sessions/.active"
echo "Claude stub returns valid response with enough words to satisfy the twenty word minimum threshold for council validation during this isolation regression test."
SH

    cat > "$td/codex" <<'SH'
#!/usr/bin/env bash
echo "CODEX_ARGS:$*" >> "${COUNCIL_STUB_CALLS:?}"
echo "Codex stub returns valid response with adequate words exceeding the twenty word minimum threshold so council can proceed to synthesis for this regression."
SH

    make_security_stub "$td"
    chmod +x "$td/claude" "$td/codex"

    (
        cd "$barrack"
        PATH="$td:$PATH" \
        AIB_COUNCIL_MAX_RETRIES=0 \
        AIB_COUNCIL_RETRY_DELAY=0 \
        "$ROOT/scripts/council.sh" -r 1 --consensus 0 --grace 0 --json \
            "isolation test" \
            > "$td/out.json" 2> "$td/err.log"
    ) || true

    [[ -f "$barrack/sessions/.active" ]] \
        || fail "[t2] sessions/.active was removed — claude ran inside the barrack cwd"

    local recorded_cwd
    recorded_cwd=$(grep '^CLAUDE_CWD:' "$COUNCIL_STUB_CALLS" | head -1 | sed 's/^CLAUDE_CWD://')
    [[ -n "$recorded_cwd" ]] || fail "[t2] claude stub never recorded its cwd"
    if [[ "$recorded_cwd" == "$barrack" ]]; then
        fail "[t2] claude ran with cwd=$barrack (expected a neutral cwd like /tmp)"
    fi
    if [[ "$recorded_cwd" != "/tmp" ]]; then
        # Not strictly required, but documents the intended fix.
        echo "  NOTE t2: claude cwd was '$recorded_cwd' (acceptable as long as it is not the barrack)" >&2
    fi

    grep -q -- '--setting-sources project,local' "$COUNCIL_STUB_CALLS" \
        || fail "[t2] claude args missing --setting-sources project,local"

    unset BARRACK_DIR COUNCIL_STUB_CALLS
    echo "  PASS  t2: claude cwd isolation + --setting-sources"
}

# ────────────────────────────────────────────────────────────
# Test 3: Orphan process cleanup on grace kill
# ────────────────────────────────────────────────────────────
test_orphan_cleanup() {
    local td="$TMP_ROOT/t3"
    mkdir -p "$td"
    export COUNCIL_STUB_CALLS="$td/calls.log"
    : > "$COUNCIL_STUB_CALLS"
    export TEST_MARKER_FILE="$td/marker.pid"

    # Fast claude stub — finishes first to trigger the grace timer.
    cat > "$td/claude" <<'SH'
#!/usr/bin/env bash
echo "CLAUDE_ARGS:$*" >> "${COUNCIL_STUB_CALLS:?}"
echo "Claude stub returns valid response with sufficient words exceeding the twenty word minimum so council can detect first-completion and start the grace timer reliably."
SH

    # Slow codex stub — spawns a long-lived "marker" subprocess and then
    # blocks. The grace-period kill must collect both the stub and its child.
    cat > "$td/codex" <<'SH'
#!/usr/bin/env bash
echo "CODEX_ARGS:$*" >> "${COUNCIL_STUB_CALLS:?}"
# Marker child: long sleep, leaks if the process-tree kill is incomplete.
( exec sleep 600 ) &
echo "$!" > "${TEST_MARKER_FILE:?}"
# Stub blocks until the watchdog/grace kill collects it.
sleep 600
SH

    make_security_stub "$td"
    chmod +x "$td/claude" "$td/codex"

    local rc=0
    PATH="$td:$PATH" \
    AIB_COUNCIL_MAX_RETRIES=0 \
    AIB_COUNCIL_RETRY_DELAY=0 \
    "$ROOT/scripts/council.sh" -r 1 --consensus 0 \
        --timeout-claude 30 --timeout-codex 30 --grace 2 --json \
        "orphan cleanup test" \
        > "$td/out.json" 2> "$td/err.log" || rc=$?

    [[ -s "$TEST_MARKER_FILE" ]] || fail "[t3] marker pidfile never written — codex stub did not run"

    local marker_pid
    marker_pid=$(cat "$TEST_MARKER_FILE")
    [[ "$marker_pid" =~ ^[0-9]+$ ]] || fail "[t3] marker pidfile is not a numeric pid: '$marker_pid'"

    # Give the kill_tree TERM→KILL sequence a moment to reap.
    local i
    for i in 1 2 3 4 5; do
        if ! kill -0 "$marker_pid" 2>/dev/null; then
            break
        fi
        sleep 1
    done

    if kill -0 "$marker_pid" 2>/dev/null; then
        kill -KILL "$marker_pid" 2>/dev/null || true
        fail "[t3] marker process (pid=$marker_pid) survived the grace/timeout kill — orphan cleanup is incomplete"
    fi

    unset TEST_MARKER_FILE COUNCIL_STUB_CALLS
    echo "  PASS  t3: orphan process cleanup"
}

echo "== test_council_hardening =="
test_false_success_prevention
test_claude_cwd_isolation
test_orphan_cleanup
echo "PASS: council hardening (false-success / cwd isolation / orphan cleanup)"
