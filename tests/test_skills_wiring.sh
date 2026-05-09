#!/usr/bin/env bash
# Integration tests for v1.2.0 skills loading wiring.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AIB_BIN="${SCRIPT_DIR}/../bin/aib"

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

FIXTURES=()
trap 'for d in "${FIXTURES[@]:-}"; do rm -rf "$d"; done' EXIT

[ -x "$AIB_BIN" ] || fail "$AIB_BIN not executable"

# --- Fixture helper ---
make_fixture_barrack() {
    local dir
    dir="$(mktemp -d)"
    FIXTURES+=("$dir")
    mkdir -p "$dir/skills/council" "$dir/skills/kanban"
    cat > "$dir/agent.yaml" <<'EOF'
name: test
description: test fixture
EOF
    cat > "$dir/skills/council/SKILL.md" <<'EOF'
---
name: council
description: "Cross-LLM debate for high-stakes decisions."
---
# Council
EOF
    cat > "$dir/skills/kanban/SKILL.md" <<'EOF'
---
name: kanban
description: "Lightweight kanban board for the barrack."
---
# Kanban
EOF
    echo "$dir"
}

# --- Test 1: inject_skills_section creates marker block in all three .md files ---
B1=$(make_fixture_barrack)

"$AIB_BIN" sync "$B1" >/dev/null 2>&1 || fail "sync failed on fixture"

for cfg in CLAUDE.md GEMINI.md AGENTS.md; do
    grep -q "<!-- AIB:SKILLS:START -->" "$B1/$cfg" || fail "$cfg missing SKILLS marker"
    grep -q "<!-- AIB:SKILLS:END -->" "$B1/$cfg" || fail "$cfg missing SKILLS end marker"
    # Verify the table row actually rendered (not just the slug name appearing somewhere)
    grep -qE '^\| `council` \|.*Cross-LLM debate' "$B1/$cfg" || fail "$cfg missing council row with description"
    grep -qE '^\| `kanban` \|.*Lightweight kanban board' "$B1/$cfg" || fail "$cfg missing kanban row with description"
done
pass "Test 1: inject_skills_section populates all three .md files"

echo "All skills wiring tests passed."
