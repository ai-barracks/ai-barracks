#!/usr/bin/env bash
# Regression: `aib council` must find council.sh next to the installed templates.
#
# Bug: the versioned manual install (docs/installation.md) puts the payload at
# ~/.local/share/ai-barracks/<version>/{templates,scripts} and rewrites only
# TEMPLATE_DIR in bin/aib. cmd_council searched `$0/../share/ai-barracks/scripts`
# (no version segment), so it failed with "council.sh not found" even though
# native-codex.sh — sourced via $(dirname "$TEMPLATE_DIR")/scripts — loaded fine.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# install_layout <prefix> <share-dir>: copy bin/aib with TEMPLATE_DIR pinned to
# <share-dir>/templates (what Formula inreplace and the manual installer do) and
# place a stub council.sh in <share-dir>/scripts.
install_layout() {
    local prefix="$1" share="$2"
    mkdir -p "$prefix/bin" "$share/templates" "$share/scripts"
    sed "s|^TEMPLATE_DIR=.*$|TEMPLATE_DIR=\"$share/templates\"|" "$ROOT/bin/aib" > "$prefix/bin/aib"
    chmod +x "$prefix/bin/aib"
    cp "$ROOT"/scripts/*.sh "$share/scripts/"   # real installs ship the whole scripts dir
    printf '#!/usr/bin/env bash\necho "STUB_COUNCIL:$*"\n' > "$share/scripts/council.sh"   # after the copy: stub wins
    chmod +x "$share/scripts/council.sh"
}

mkdir -p "$TMP/work"   # cwd without ./scripts/council.sh
unset AIB_COUNCIL_SCRIPT

# --- Test 1: versioned manual install payload ---------------------------------
install_layout "$TMP/manual" "$TMP/manual/share/ai-barracks/9.9.9"
out="$(cd "$TMP/work" && "$TMP/manual/bin/aib" council "topic one" 2>&1)" \
    || fail "versioned install: aib council exited non-zero: $out"
[ "$out" = "STUB_COUNCIL:topic one" ] || fail "versioned install: unexpected output: $out"
pass "versioned manual install finds council.sh beside TEMPLATE_DIR"

# --- Test 2: Homebrew-style unversioned pkgshare still works -------------------
install_layout "$TMP/brew" "$TMP/brew/share/ai-barracks"
out="$(cd "$TMP/work" && "$TMP/brew/bin/aib" council -r 1 "topic two" 2>&1)" \
    || fail "brew layout: aib council exited non-zero: $out"
[ "$out" = "STUB_COUNCIL:-r 1 topic two" ] || fail "brew layout: unexpected output: $out"
pass "Homebrew pkgshare layout still resolves council.sh"

# --- Test 3: AIB_COUNCIL_SCRIPT keeps highest priority -------------------------
printf '#!/usr/bin/env bash\necho "ENV_COUNCIL:$*"\n' > "$TMP/env-council.sh"
chmod +x "$TMP/env-council.sh"
out="$(cd "$TMP/work" && AIB_COUNCIL_SCRIPT="$TMP/env-council.sh" "$TMP/manual/bin/aib" council "t" 2>&1)" \
    || fail "env override: exited non-zero: $out"
[ "$out" = "ENV_COUNCIL:t" ] || fail "env override: unexpected output: $out"
pass "AIB_COUNCIL_SCRIPT override wins"

echo "All council lookup tests passed."
