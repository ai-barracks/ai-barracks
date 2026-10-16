#!/usr/bin/env bash
# Regression: session end must never rewrite agent-written records or delete raw evidence.
#
# summarize_session() piped the raw capture to `claude -p` (hooks on, barrack cwd),
# replaced everything after "## Log" with the model output, then deleted the raw file.
# It was unreachable until v1.5.0 fixed the `aib start` wrapper's EXIT trap, which made
# it run on every Gemini/Codex wrapper exit (CC launches agents through `aib start`).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AIB_BIN="${SCRIPT_DIR}/../bin/aib"
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
AIB_SOURCE_ONLY=1 source "$AIB_BIN"
set +e
mkdir -p "$TMP/b/sessions" "$TMP/stubs"
cp "$TEMPLATE_DIR/SESSIONS.md" "$TMP/b/SESSIONS.md"
cd "$TMP/b" || fail "cd"

# The "agent" writes its own records into its session file, as the protocol requires.
cat > "$TMP/stubs/gemini" <<'SH'
#!/bin/bash
f="sessions/${MAP_SESSION_ID}.md"
sed -i '' 's/^- \*\*Task\*\*: .*/- **Task**: agent task/' "$f" 2>/dev/null || sed -i 's/^- \*\*Task\*\*: .*/- **Task**: agent task/' "$f"
awk '{print} /^## Decisions/{print "- AGENT-DECISION kept"}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
printf -- '- [09:00] AGENT-LOG kept\n' >> "$f"
echo "terminal output that is the only raw evidence"
SH
# A summarizer stub: records that it ran and returns a plausible replacement.
cat > "$TMP/stubs/claude" <<SH
#!/bin/bash
touch "$TMP/claude_invoked"
printf '## Log\n- [00:00] FAKE-SUMMARY\n'
SH
chmod +x "$TMP/stubs/gemini" "$TMP/stubs/claude"

PATH="$TMP/stubs:$PATH" "$AIB_BIN" start gemini "wrapper task" </dev/null >/dev/null 2>&1
SID="$(ls sessions/gemini-*.md | head -1 | xargs basename | sed 's/\.md$//')"
MD="sessions/${SID}.md"
[ -n "$SID" ] || fail "no wrapper session created"
grep -q '^- \*\*Status\*\*: completed' "$MD" || fail "wrapper did not complete the session"
grep -q 'AGENT-LOG kept' "$MD" || fail "agent-written Log was removed"
grep -q 'AGENT-DECISION kept' "$MD" || fail "agent-written Decisions were removed"
grep -q 'FAKE-SUMMARY' "$MD" && fail "model output was written into the session record"
[ ! -e "$TMP/claude_invoked" ] || fail "session end must not call claude -p"
[ -s "sessions/${SID}.raw" ] || fail "raw capture (the only raw evidence) was deleted"
[ "$(_aib_seal_state "$SID")" = intact ] || fail "session should be sealed intact"
pass "wrapper exit keeps agent records and raw capture, never calls an LLM"
echo "All wrapper summary tests passed."
