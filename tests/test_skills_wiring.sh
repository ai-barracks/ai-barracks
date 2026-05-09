#!/usr/bin/env bash
# Integration tests for v1.2.0 skills loading wiring.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AIB_BIN="${SCRIPT_DIR}/../bin/aib"

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

[ -x "$AIB_BIN" ] || fail "$AIB_BIN not executable"

# --- Fixture helper ---
make_fixture_barrack() {
    local dir
    dir="$(mktemp -d)"
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
T1=$(mktemp -d)
trap 'rm -rf "$T1"' EXIT
B1=$(make_fixture_barrack)

"$AIB_BIN" sync "$B1" >/dev/null 2>&1 || fail "sync failed on fixture"

for cfg in CLAUDE.md GEMINI.md AGENTS.md; do
    grep -q "<!-- AIB:SKILLS:START -->" "$B1/$cfg" || fail "$cfg missing SKILLS marker"
    grep -q "<!-- AIB:SKILLS:END -->" "$B1/$cfg" || fail "$cfg missing SKILLS end marker"
    grep -q "council" "$B1/$cfg" || fail "$cfg does not list 'council'"
    grep -q "kanban" "$B1/$cfg" || fail "$cfg does not list 'kanban'"
done
pass "Test 1: inject_skills_section populates all three .md files"

rm -rf "$B1"
echo "All skills wiring tests passed."
