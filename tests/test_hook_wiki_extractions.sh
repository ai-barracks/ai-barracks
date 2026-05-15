#!/usr/bin/env bash
# Regression tests for SessionStart hook's "no Wiki Extractions" detector.
#
# Bug fixed: variant F in wiki/topics/AIB-Hook-Stale-Cleanup-Bug.md.
# `cmd_hook_start` previously used `grep -A1 "## Wiki Extractions"` which only
# looked at the single line immediately following the header. The standard
# session template puts a 4-line guidance comment block right after the header,
# so any real `- ` bullet placed below the comments was invisible and an alert
# fired even though the author had recorded extractions correctly. The same
# blindness hit `(없음 — wiki: ... / RULES: ... / SOUL: ...)` parenthetical
# "no extractions with reason" lines, which the template itself recommends.
#
# These tests pin the new behavior: a Wiki Extractions section is considered
# populated as long as it contains *any* non-blank, non-comment line.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AIB_BIN="${SCRIPT_DIR}/../bin/aib"

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

FIXTURES=()
# Clean up both the on-disk fixture directories AND any registry entries
# (~/.aib/barracks.json) that `aib hook start` may have written for them.
cleanup_fixtures() {
    for d in "${FIXTURES[@]:-}"; do
        [ -z "$d" ] && continue
        "$AIB_BIN" barracks remove "$d" >/dev/null 2>&1 || true
        rm -rf "$d"
    done
}
trap cleanup_fixtures EXIT

[ -x "$AIB_BIN" ] || fail "$AIB_BIN not executable"

# --- Fixture barrack with a single completed previous session -------------
# We don't need the full init; only the layout the hook reads:
#   - SESSIONS.md          (so the hook can list prior rows)
#   - sessions/{id}.md     (the session whose Wiki Extractions we vary)
#   - .active              (so the hook knows the current session id)
make_fixture() {
    local body_kind="$1"   # "real-bullet" | "parenthetical" | "comments-only" | "truly-empty"
    local dir
    dir="$(mktemp -d)"
    FIXTURES+=("$dir")
    mkdir -p "$dir/sessions"
    cat > "$dir/SESSIONS.md" <<'EOF'
# Sessions
| Session ID | Client | Started | Last Update | Status |
|------------|--------|---------|-------------|--------|
EOF
    # Prior session — completed, with the chosen Wiki Extractions body
    local prev="$dir/sessions/codex-20260101-0000.md"
    cat > "$prev" <<'EOF'
<!-- AIB:OWNERSHIP -->
# Session: codex-20260101-0000

- **Client**: Codex CLI
- **Started**: 2026-01-01 00:00
- **Ended**: 2026-01-01 00:10
- **Status**: completed
- **Task**: fixture task

## Log
- [00:01] something → done
- [00:05] another thing → done

## Decisions

## Blockers

## Retries

EOF
    # Append the Wiki Extractions section under test
    case "$body_kind" in
        real-bullet)
            cat >> "$prev" <<'EOF'
## Wiki Extractions
<!-- 세션 중/종료 시 작성. wiki, RULES.md 갱신 내역을 모두 기록 -->
<!-- 갱신 없으면 분류별 사유 기술. 단순 "(없음)" 금지 -->
<!-- Format: - {파일} — {내용 한 줄 요약} -->
<!-- 예: (없음 — wiki: 단순 오타 수정 / RULES: 교정·실패 없음 / SOUL: 해당 없음) -->
- wiki/topics/Foo.md — added Foo bar baz

## Identity Suggestions
EOF
            ;;
        parenthetical)
            cat >> "$prev" <<'EOF'
## Wiki Extractions
- (없음 — wiki: 일회성 평가로 새 영속 지식 없음 / RULES: 교정·실패 없음 / SOUL: 해당 없음)
<!-- 세션 중/종료 시 작성. wiki, RULES.md 갱신 내역을 모두 기록 -->
<!-- 갱신 없으면 분류별 사유 기술. 단순 "(없음)" 금지 -->

## Identity Suggestions
EOF
            ;;
        comments-only)
            cat >> "$prev" <<'EOF'
## Wiki Extractions
<!-- 세션 중/종료 시 작성. wiki, RULES.md 갱신 내역을 모두 기록 -->
<!-- 갱신 없으면 분류별 사유 기술. 단순 "(없음)" 금지 -->
<!-- Format: - {파일} — {내용 한 줄 요약} -->
<!-- 예: (없음 — wiki: 단순 오타 수정 / RULES: 교정·실패 없음 / SOUL: 해당 없음) -->

## Identity Suggestions
EOF
            ;;
        truly-empty)
            cat >> "$prev" <<'EOF'
## Wiki Extractions

## Identity Suggestions
EOF
            ;;
    esac
    echo "$dir"
}

# Run the SessionStart hook against a fixture and capture stdout.
# The hook is `cmd_hook_start` reached via `aib hook start <client>`.
run_hook() {
    local dir="$1"
    (
        cd "$dir"
        "$AIB_BIN" hook start claude 2>/dev/null
    )
}

# --- Test 1: real bullet under template comments → NO alert ---------------
D1=$(make_fixture real-bullet)
out=$(run_hook "$D1")
if echo "$out" | grep -q "has no Wiki Extractions"; then
    echo "$out"
    fail "real-bullet: false positive alert fired"
fi
pass "real-bullet: bullet placed after template comments is recognized"

# --- Test 2: parenthetical reason on header-adjacent line → NO alert -----
D2=$(make_fixture parenthetical)
out=$(run_hook "$D2")
if echo "$out" | grep -q "has no Wiki Extractions"; then
    echo "$out"
    fail "parenthetical: false positive alert fired"
fi
pass "parenthetical: '- (없음 — ...)' reason line is recognized"

# --- Test 3: only HTML comments, no real content → alert FIRES -----------
D3=$(make_fixture comments-only)
out=$(run_hook "$D3")
if ! echo "$out" | grep -q "has no Wiki Extractions"; then
    echo "$out"
    fail "comments-only: alert should have fired but did not"
fi
pass "comments-only: section with only template comments still triggers alert"

# --- Test 4: section is truly blank → alert FIRES -------------------------
D4=$(make_fixture truly-empty)
out=$(run_hook "$D4")
if ! echo "$out" | grep -q "has no Wiki Extractions"; then
    echo "$out"
    fail "truly-empty: alert should have fired but did not"
fi
pass "truly-empty: blank section still triggers alert"

echo ""
echo "All Wiki Extractions detection tests passed."
