#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/project"; cd "$TMP/project"
export PROFILE_ARGS="$TMP/args"
cat > "$TMP/bin/claude" <<'SH'
#!/bin/bash
printf '%s\n' "$@" > "$PROFILE_ARGS"
SH
chmod +x "$TMP/bin/claude"
PATH="$TMP/bin:$PATH" "$ROOT/bin/aib" start claude --model "custom';touch nope" --effort high 'task | & back\slash' >/dev/null 2>&1
grep -qx 'high' "$PROFILE_ARGS"; grep -qx "custom';touch nope" "$PROFILE_ARGS"; grep -qxF 'task | & back\slash' "$PROFILE_ARGS"
[ ! -e nope ]
if PATH="$TMP/bin:$PATH" "$ROOT/bin/aib" start claude --effort 'high";bad' >/dev/null 2>&1; then exit 1; fi
if "$ROOT/bin/aib" start codex --model >/dev/null 2>&1; then exit 1; fi
AIB_SOURCE_ONLY=1 source "$ROOT/bin/aib"
render_session_context test Codex now 'task | & back\slash' > context
grep -qF 'task | & back\slash' context
echo 'PASS: model/effort/task forwarding and literal context rendering'
