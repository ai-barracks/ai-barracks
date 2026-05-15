#!/usr/bin/env bash
# Tests for `aib barracks gc` and the ephemeral-path guard on register_barrack.
#
# Background: ai-barracks's own integration tests used to leak fixture entries
# into ~/.aib/barracks.json because `aib sync` / `aib init` called
# `register_barrack` on `mktemp -d` directories, and the test trap only deleted
# the directory afterwards. v1.2.2 adds two defenses:
#   1. `_is_ephemeral_path` makes `register_barrack` skip /tmp, /var/folders,
#      /private/tmp, /private/var/folders, and any basename matching `tmp.*`.
#      Override with `AIB_REGISTER_FORCE=1` when you really need the entry.
#   2. `aib barracks gc [--dry-run]` prunes registry entries whose path is
#      either ephemeral or missing on disk.
#
# These tests pin both behaviors against an isolated `AIB_REGISTRY`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AIB_BIN="${SCRIPT_DIR}/../bin/aib"

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

[ -x "$AIB_BIN" ] || fail "$AIB_BIN not executable"

# --- Isolated HOME so we never touch the real ~/.aib/barracks.json --------
ISOLATED_HOME="$(mktemp -d)"
trap 'rm -rf "$ISOLATED_HOME"' EXIT

export HOME="$ISOLATED_HOME"
# Re-derive registry path under the isolated HOME
REG="$ISOLATED_HOME/.aib/barracks.json"

# --- Test 1: register_barrack refuses /tmp paths by default ---------------
EPHEMERAL_FIXTURE="$(mktemp -d)"
"$AIB_BIN" init "$EPHEMERAL_FIXTURE" >/dev/null 2>&1 || fail "init failed on ephemeral fixture"

if [ -f "$REG" ] && jq -e --arg p "$EPHEMERAL_FIXTURE" '.[] | select(.path == $p)' "$REG" >/dev/null 2>&1; then
    fail "ephemeral guard: $EPHEMERAL_FIXTURE was registered despite ephemeral path"
fi
pass "ephemeral guard: register_barrack silently skipped /var/folders path"

# --- Test 2: AIB_REGISTER_FORCE=1 bypasses the guard ----------------------
# Use a path under /var/folders so it would be skipped without the override,
# then verify it lands in the registry. We don't actually need the directory
# to exist for register_barrack to write the JSON entry.
FORCED_PATH="${ISOLATED_HOME}/forced-ephemeral"
mkdir -p "$FORCED_PATH"
AIB_REGISTER_FORCE=1 "$AIB_BIN" init "$FORCED_PATH" >/dev/null 2>&1 \
    || fail "init failed on forced ephemeral path"

if ! jq -e --arg p "$FORCED_PATH" '.[] | select(.path == $p)' "$REG" >/dev/null 2>&1; then
    fail "force opt-out: AIB_REGISTER_FORCE=1 did not register $FORCED_PATH"
fi
pass "force opt-out: AIB_REGISTER_FORCE=1 registers ephemeral paths on demand"

# --- Test 3: gc removes ephemeral entries and missing-on-disk entries -----
# Inject a legitimate-looking entry that should survive GC — point at a
# non-ephemeral directory we know exists (the ai-barracks repo root itself).
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
jq --arg p "$REPO_ROOT" '. + [
    {"path": $p, "name": "ai-barracks-repo", "description": "test legit entry", "expertise": "", "topics": ""},
    {"path": "/var/folders/leaked/tmp.LEAK1", "name": "leak1", "description": "", "expertise": "", "topics": ""},
    {"path": "/tmp/leak2", "name": "leak2", "description": "", "expertise": "", "topics": ""},
    {"path": "/var/folders/leaked/tmp.LEAK3/fresh", "name": "fresh", "description": "", "expertise": "", "topics": ""},
    {"path": "'"$ISOLATED_HOME"'/gone-on-disk", "name": "gone", "description": "", "expertise": "", "topics": ""}
]' "$REG" > "${REG}.tmp" && mv "${REG}.tmp" "$REG"

before_count=$(jq length "$REG")
[ "$before_count" -ge 5 ] || fail "fixture setup: expected >=5 entries before gc, got $before_count"

# Dry-run should not mutate the file
"$AIB_BIN" barracks gc --dry-run >/dev/null 2>&1 || fail "gc --dry-run errored"
after_dry=$(jq length "$REG")
[ "$after_dry" = "$before_count" ] || fail "gc --dry-run mutated registry ($before_count -> $after_dry)"
pass "gc --dry-run reports without mutating the registry"

# Real run: removes the 4 manually-injected stale entries PLUS the forced
# ephemeral entry from Test 2 (gc treats ephemeral paths uniformly — the
# AIB_REGISTER_FORCE override only affects writes, not GC).
"$AIB_BIN" barracks gc >/dev/null 2>&1 || fail "gc errored"
after_real=$(jq length "$REG")

# The legit repo-root entry must remain
if ! jq -e --arg p "$REPO_ROOT" '.[] | select(.path == $p)' "$REG" >/dev/null 2>&1; then
    fail "gc removed the legitimate repo-root entry — over-eager prune"
fi
pass "gc preserved the legitimate non-ephemeral repo-root entry"

# Verify gc removed exactly the ephemeral/missing ones
for stale_path in \
    "/var/folders/leaked/tmp.LEAK1" \
    "/tmp/leak2" \
    "/var/folders/leaked/tmp.LEAK3/fresh" \
    "$ISOLATED_HOME/gone-on-disk" \
    "$FORCED_PATH"
do
    if jq -e --arg p "$stale_path" '.[] | select(.path == $p)' "$REG" >/dev/null 2>&1; then
        fail "gc failed to remove ephemeral/missing path: $stale_path"
    fi
done
pass "gc removed all ephemeral and missing-on-disk entries"

echo ""
echo "All barracks GC / ephemeral-guard tests passed."
