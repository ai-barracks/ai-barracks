#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
AIB_SOURCE_ONLY=1 source "$ROOT/bin/aib"
fail() { echo "FAIL: $*" >&2; exit 1; }
for native in .claude .agents; do
    b="$TMP/${native#.}"; mkdir -p "$b/skills/sample" "$b/$native/skills/sample"
    printf '%s\n' '---' 'name: sample' 'description: regression' '---' > "$b/skills/sample/SKILL.md"
    echo user > "$b/$native/skills/sample/keep"
    if sync_native_skills_symlinks "$b" "$native"; then fail "directory conflict accepted"; fi
    [ "$(cat "$b/$native/skills/sample/keep")" = user ] || fail "user content deleted"
    rm -rf "$b/$native/skills/sample"
    ln -s "$TMP/user" "$b/$native/skills/sample"
    if sync_native_skills_symlinks "$b" "$native"; then fail "foreign symlink accepted"; fi
    [ "$(readlink "$b/$native/skills/sample")" = "$TMP/user" ] || fail "foreign link changed"
    rm "$b/$native/skills/sample"
    sync_native_skills_symlinks "$b" "$native"
    [ "$(readlink "$b/$native/skills/sample")" = '../../skills/sample' ] || fail "wrong native target"
    mkdir -p "$b/$native/skills/custom"; echo user > "$b/$native/skills/custom/keep"
    rm "$b/skills/sample/SKILL.md"
    sync_native_skills_symlinks "$b" "$native"
    [ ! -L "$b/$native/skills/sample" ] || fail "orphan link not removed"
    [ -f "$b/$native/skills/custom/keep" ] || fail "native custom skill deleted"
    mv "$b/$native/skills" "$b/saved"
    ln -s "$b/saved" "$b/$native/skills"
    if sync_native_skills_symlinks "$b" "$native"; then fail "symlinked native parent accepted"; fi
done
echo 'PASS: Claude/Codex native skill collision, orphan and parent safety'
