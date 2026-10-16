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

PATH="$TMP/stubs:$PATH" "$AIB_BIN" start gemini "wrapper task" </dev/null >/dev/null 2>&1 || fail "aib start exited non-zero"
SID="$(ls sessions/gemini-*.md | head -1 | xargs basename | sed 's/\.md$//')"
MD="sessions/${SID}.md"
[ -n "$SID" ] || fail "no wrapper session created"
grep -q '^- \*\*Status\*\*: completed' "$MD" || fail "wrapper did not complete the session"
grep -q 'AGENT-LOG kept' "$MD" || fail "agent-written Log was removed"
grep -q 'AGENT-DECISION kept' "$MD" || fail "agent-written Decisions were removed"
grep -q 'FAKE-SUMMARY' "$MD" && fail "model output was written into the session record"
[ ! -e "$TMP/claude_invoked" ] || fail "session end must not call claude -p"
[ -s "sessions/${SID}.raw" ] || fail "raw capture (the only raw evidence) was deleted"
grep -q "only raw evidence" "sessions/${SID}.raw" || fail "raw capture lost the agent output"
[ "$(stat -f %Lp "sessions/${SID}.raw" 2>/dev/null || stat -c %a "sessions/${SID}.raw")" = 600 ] || fail "raw capture must be private (0600)"
grep -qx "sessions/\*.raw" .gitignore || fail "raw captures must be git-ignored"
[ "$(_aib_seal_state "$SID")" = intact ] || fail "session should be sealed intact"
pass "wrapper exit keeps agent records and raw capture, never calls an LLM"
# --- Claude SessionEnd: a transcript path in the environment is never consumed ---
HOLDER_PID=$$
printf '{"type":"user"}\n' > "$TMP/transcript.jsonl"
AIB_LIVE_PID=$HOLDER_PID "$AIB_BIN" hook start claude >/dev/null 2>&1
CSID="$(cat sessions/.active)"; CMD="sessions/${CSID}.md"
_sed_inplace "$CMD" -e 's/^- \*\*Task\*\*: (pending)/- **Task**: claude task/'
printf -- '- [10:00] CLAUDE-LOG kept\n' >> "$CMD"
rm -f "$TMP/claude_invoked"
PATH="$TMP/stubs:$PATH" CLAUDE_TRANSCRIPT_PATH="$TMP/transcript.jsonl" AIB_LIVE_PID=$HOLDER_PID \
    "$AIB_BIN" hook end claude >/dev/null 2>&1 || fail "hook end exited non-zero"
[ -s "$TMP/transcript.jsonl" ] || fail "Claude transcript was deleted at session end"
[ ! -e "$TMP/claude_invoked" ] || fail "Claude session end must not call claude -p"
grep -q 'CLAUDE-LOG kept' "$CMD" || fail "Claude session Log was rewritten"
grep -q '^## Summary (auto-generated)' "$CMD" || fail "deterministic summary missing"
[ "$(_aib_seal_state "$CSID")" = intact ] || fail "Claude session should be sealed after the summary"
pass "Claude session end keeps the transcript and records, writes only the deterministic summary"

# --- A session with records but no Task/Log is kept, not deleted as empty ---
AIB_LIVE_PID=$HOLDER_PID "$AIB_BIN" hook start claude >/dev/null 2>&1
DSID="$(cat sessions/.active)"; DMD="sessions/${DSID}.md"
awk '{print} /^## Decisions/{print "- ONLY-A-DECISION"}' "$DMD" > "$DMD.tmp" && mv "$DMD.tmp" "$DMD"
AIB_LIVE_PID=$HOLDER_PID "$AIB_BIN" hook end claude >/dev/null 2>&1
[ -f "$DMD" ] && grep -q 'ONLY-A-DECISION' "$DMD" || fail "session with a Decision was deleted as empty"
AIB_LIVE_PID=$HOLDER_PID "$AIB_BIN" hook start claude >/dev/null 2>&1
ESID="$(cat sessions/.active)"
AIB_LIVE_PID=$HOLDER_PID "$AIB_BIN" hook end claude >/dev/null 2>&1
[ ! -f "sessions/${ESID}.md" ] || fail "a truly empty session should still be deleted"
pass "only truly empty sessions are deleted at session end"
echo "All wrapper summary tests passed."
