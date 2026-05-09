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

# --- Test 2: sync is idempotent for skills section ---
B2=$(make_fixture_barrack)
"$AIB_BIN" sync "$B2" >/dev/null 2>&1
HASH1=$(cat "$B2/CLAUDE.md" | md5)
"$AIB_BIN" sync "$B2" >/dev/null 2>&1
HASH2=$(cat "$B2/CLAUDE.md" | md5)
[ "$HASH1" = "$HASH2" ] || fail "CLAUDE.md not idempotent under double sync ($HASH1 vs $HASH2)"
pass "Test 2: sync is idempotent"

# --- Test 3: user content above and below SKILLS markers is preserved ---
B3=$(make_fixture_barrack)
"$AIB_BIN" sync "$B3" >/dev/null 2>&1
# Insert user content above and below the SKILLS block
python3 - "$B3/CLAUDE.md" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text()
sm = "<!-- AIB:SKILLS:START -->"
em = "<!-- AIB:SKILLS:END -->"
i = text.index(sm)
j = text.index(em) + len(em)
new = text[:i] + "\n## My Custom Section Above\nHello above.\n\n" + text[i:j] + "\n\n## My Custom Section Below\nHello below.\n" + text[j:]
p.write_text(new)
PY
"$AIB_BIN" sync "$B3" >/dev/null 2>&1
grep -q "My Custom Section Above" "$B3/CLAUDE.md" || fail "user content above SKILLS markers was lost"
grep -q "My Custom Section Below" "$B3/CLAUDE.md" || fail "user content below SKILLS markers was lost"
pass "Test 3: user content outside markers preserved"

# --- Test 4: aib sync creates relative symlinks under .claude/skills/ ---
B4=$(make_fixture_barrack)
"$AIB_BIN" sync "$B4" >/dev/null 2>&1
[ -L "$B4/.claude/skills/council" ] || fail ".claude/skills/council symlink not created"
[ -L "$B4/.claude/skills/kanban" ] || fail ".claude/skills/kanban symlink not created"
target=$(readlink "$B4/.claude/skills/council")
[ "$target" = "../../skills/council" ] || fail "council symlink target wrong: '$target' (expected ../../skills/council)"
# Resolve through the symlink to confirm it points to a real directory containing SKILL.md
[ -f "$B4/.claude/skills/council/SKILL.md" ] || fail "council symlink does not resolve to SKILL.md"
pass "Test 4: relative symlinks created and resolve"

# --- Test 5: deleting a skill removes the corresponding symlink ---
B5=$(make_fixture_barrack)
"$AIB_BIN" sync "$B5" >/dev/null 2>&1
[ -L "$B5/.claude/skills/kanban" ] || fail "precondition: kanban symlink not present"
rm -rf "$B5/skills/kanban"
"$AIB_BIN" sync "$B5" >/dev/null 2>&1
[ ! -e "$B5/.claude/skills/kanban" ] || fail "orphan kanban symlink not removed"
[ -L "$B5/.claude/skills/council" ] || fail "council symlink should remain"
pass "Test 5: orphan symlink removed when skill deleted"

# --- Test 6: renaming a skill slug yields a new symlink (and old one cleaned) ---
B6=$(make_fixture_barrack)
"$AIB_BIN" sync "$B6" >/dev/null 2>&1
mv "$B6/skills/kanban" "$B6/skills/sprint"
# Update SKILL.md frontmatter to match new slug
sed -i '' 's/name: kanban/name: sprint/' "$B6/skills/sprint/SKILL.md"
"$AIB_BIN" sync "$B6" >/dev/null 2>&1
[ -L "$B6/.claude/skills/sprint" ] || fail "sprint symlink not created after rename"
[ ! -e "$B6/.claude/skills/kanban" ] || fail "old kanban symlink not cleaned after rename"
pass "Test 6: slug rename refreshes symlinks"

# --- Test 7: check_skills_drift detects post-sync edits ---
B7=$(make_fixture_barrack)
"$AIB_BIN" sync "$B7" >/dev/null 2>&1
# In-sync: command should succeed silently
"$AIB_BIN" skills doctor "$B7" >/dev/null 2>&1 || fail "doctor failed on freshly-synced barrack"
# Now add a new skill WITHOUT running sync — drift!
mkdir -p "$B7/skills/retrospective"
cat > "$B7/skills/retrospective/SKILL.md" <<'EOF'
---
name: retrospective
description: "End-of-sprint retrospective facilitation."
---
EOF
# Doctor should now warn about drift
out="$("$AIB_BIN" skills doctor "$B7" 2>&1 || true)"
echo "$out" | grep -qi "drift\|out of sync\|sync needed" || fail "doctor did not detect new skill as drift: $out"
pass "Test 7: drift detected after adding skill without sync"

echo "All skills wiring tests passed."
