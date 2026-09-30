#!/usr/bin/env bash
# Isolate config/registry and prevent unmocked provider or credential invocations.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/stubs"
for name in claude codex gemini security; do
    printf '#!/bin/sh\necho "Unmocked provider/credential invocation refused" >&2\nexit 99\n' > "$TMP/stubs/$name"
    chmod +x "$TMP/stubs/$name"
done
export HOME="$TMP/home" PATH="$TMP/stubs:$PATH"
unset AIB_REGISTRY
export AIB_CLAUDE_SETTINGS="$TMP/home/claude-settings.json" AIB_GEMINI_SETTINGS="$TMP/home/gemini-settings.json"
for test in "$ROOT"/tests/*.sh; do
    [ "$(basename "$test")" = run.sh ] && continue
    echo "=== $(basename "$test") ==="
    /bin/bash "$test"
done
