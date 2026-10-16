#!/usr/bin/env bash
# Claude transcript archive (v1.6.0): Claude Code deletes ~/.claude/projects/*/*.jsonl after
# cleanupPeriodDays, so aib keeps a private, verified gzip copy plus a metadata-only digest.
# The SessionEnd hook only records intent (it is killed after ~0.9s); a worker copies,
# verifies and digests under a per-uuid lock. AIB_ARCHIVE_SYNC=1 runs the worker inline.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AIB_BIN="${SCRIPT_DIR}/../bin/aib"
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

TMP="$(mktemp -d)"
sleep 600 & HOLDER=$!
trap 'kill "$HOLDER" 2>/dev/null; wait 2>/dev/null; rm -rf "$TMP"' EXIT

export CLAUDE_CONFIG_DIR="$TMP/claude" AIB_ARCHIVE_DIR="$TMP/archive" AIB_ARCHIVE_SYNC=1
AIB_SOURCE_ONLY=1 source "$AIB_BIN"
set +e

BR="$TMP/barrack"; mkdir -p "$BR/sessions"
cp "$TEMPLATE_DIR/SESSIONS.md" "$BR/SESSIONS.md"
BR_REAL="$(cd "$BR" && pwd -P)"
SLUG="$(printf '%s' "$BR_REAL" | sed 's#[/.]#-#g')"
PROJ="$CLAUDE_CONFIG_DIR/projects/$SLUG"; mkdir -p "$PROJ"
UUID="11111111-2222-3333-4444-555555555555"
SRC="$PROJ/$UUID.jsonl"
cat > "$SRC" <<EOF
{"type":"user","sessionId":"$UUID","cwd":"$BR_REAL","timestamp":"2026-10-16T01:00:00Z","message":{"role":"user","content":"hello SECRET-PROMPT"}}
{"type":"assistant","timestamp":"2026-10-16T01:00:05Z","message":{"id":"m1","model":"claude-x","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/private/SECRET-PATH"}}],"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":1,"cache_read_input_tokens":2}}}
{"type":"assistant","timestamp":"2026-10-16T01:00:06Z","message":{"id":"m1","model":"claude-x","content":[{"type":"tool_use","name":"mcp__secretserver__do","input":{}}],"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":1,"cache_read_input_tokens":2}}}
{"type":"user","timestamp":"2026-10-16T01:00:07Z","message":{"content":[{"type":"tool_result","is_error":true,"content":"boom SECRET-OUTPUT"}]}}
{"type":"assistant","isSidechain":true,"timestamp":"2026-10-16T01:00:08Z","message":{"id":"s1","content":[],"usage":{"input_tokens":100,"output_tokens":100}}}
{"type":"user","isMeta":true,"timestamp":"2026-10-16T01:00:09Z","message":{"content":"<injected>"}}
{this line is truncated
EOF
cd "$BR" || fail "cd"

payload() { printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"%s"}' "$1" "$2" "$BR_REAL" "$3"; }
gz_sha() { gzip -dc "$1" | shasum -a 256 | cut -d' ' -f1; }
src_sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
state_of() { sed -n "s/^$2=//p" "$AIB_ARCHIVE_DIR/.state/$1" 2>/dev/null; }

# --- 1. SessionStart + SessionEnd archive the transcript, verified and private ---------
payload "$UUID" "$SRC" SessionStart | AIB_LIVE_PID="$HOLDER" "$AIB_BIN" hook start claude >/dev/null 2>&1
SID="$(cat sessions/.active)"
_sed_inplace "sessions/$SID.md" -e 's/^- \*\*Task\*\*: (pending)/- **Task**: archive/'
printf -- '- [01:00] work\n' >> "sessions/$SID.md"
payload "$UUID" "$SRC" SessionEnd | AIB_LIVE_PID="$HOLDER" "$AIB_BIN" hook end claude >/dev/null 2>&1 || fail "hook end failed"
ARC="$AIB_ARCHIVE_DIR/claude/$UUID.jsonl.gz"
[ -f "$ARC" ] || fail "transcript not archived"
[ "$(gz_sha "$ARC")" = "$(src_sha "$SRC")" ] || fail "archive content differs from source"
[ "$(stat -f %Lp "$ARC" 2>/dev/null || stat -c %a "$ARC")" = 600 ] || fail "archive must be 0600"
[ "$(stat -f %Lp "$AIB_ARCHIVE_DIR" 2>/dev/null || stat -c %a "$AIB_ARCHIVE_DIR")" = 700 ] || fail "archive dir must be 0700"
[ "$(state_of "$UUID" state)" = succeeded ] || fail "state should be succeeded, got $(state_of "$UUID" state)"
case ",$(state_of "$UUID" sids)," in *",$SID,"*) ;; *) fail "state should map sid $SID";; esac
[ "$(_aib_seal_state "$SID")" = intact ] || fail "session record must stay sealed and untouched"
pass "SessionEnd archives a verified 0600 copy and maps the aib session"

# --- 2. Digest is metadata-only, dedups tokens by message.id, separates sidechains ------
DIG="$AIB_ARCHIVE_DIR/.digest/$UUID.json"
[ -f "$DIG" ] || fail "digest missing"
jq -e '.schema == 1 and .scope == "cumulative" and .user_prompts == 1 and .assistant_turns == 1
       and .tool_calls.Read == 1 and .tool_calls.mcp == 1 and .tool_errors == 1
       and .tokens.input == 10 and .tokens.output == 5 and .tokens.cache_creation == 1 and .tokens.cache_read == 2
       and .sidechain_records == 1 and .parse_failures == 1 and .models == ["claude-x"]
       and .first_ts == "2026-10-16T01:00:00Z"' "$DIG" >/dev/null || { cat "$DIG"; fail "digest values"; }
grep -qE 'SECRET|secretserver|hello' "$DIG" && fail "digest leaked prompt/path/output/MCP server text"
pass "digest is metadata-only with deduped tokens, sidechain and parse-failure counts"

# --- 3. Resume growth replaces in place; unchanged source is a no-op ---------------------
printf '{"type":"user","timestamp":"2026-10-16T02:00:00Z","message":{"content":"second"}}\n' >> "$SRC"
"$AIB_BIN" archive run "$UUID" >/dev/null 2>&1 || fail "archive run failed"
[ "$(gz_sha "$ARC")" = "$(src_sha "$SRC")" ] || fail "prefix growth should replace the archive"
[ "$(ls "$AIB_ARCHIVE_DIR/claude" | grep -c "^$UUID")" = 1 ] || fail "growth must not create variants"
before="$(stat -f %m "$ARC" 2>/dev/null || stat -c %Y "$ARC")"; sleep 1
"$AIB_BIN" archive run "$UUID" >/dev/null 2>&1
[ "$(stat -f %m "$ARC" 2>/dev/null || stat -c %Y "$ARC")" = "$before" ] || fail "unchanged source must not rewrite"
pass "resume growth replaces in place; unchanged source is skipped"

# --- 4. Divergent rewrite keeps the old copy and stores the new one beside it ------------
old_sha="$(gz_sha "$ARC")"
sed -i '' 's/hello SECRET-PROMPT/rewritten/' "$SRC" 2>/dev/null || sed -i 's/hello SECRET-PROMPT/rewritten/' "$SRC"
"$AIB_BIN" archive run "$UUID" >/dev/null 2>&1
[ "$(gz_sha "$ARC")" = "$old_sha" ] || fail "divergent source must not overwrite the existing archive"
VAR="$AIB_ARCHIVE_DIR/claude/$UUID.$(src_sha "$SRC" | cut -c1-12).jsonl.gz"
[ -f "$VAR" ] && [ "$(gz_sha "$VAR")" = "$(src_sha "$SRC")" ] || fail "divergent copy not stored as a variant"
pass "divergent rewrite is kept as a separate variant, nothing overwritten"

# --- 5. Path validation: outside the projects dir or name mismatch is refused -------------
mkdir -p "$TMP/elsewhere"; cp "$SRC" "$TMP/elsewhere/22222222-2222-3333-4444-555555555555.jsonl"
payload 22222222-2222-3333-4444-555555555555 "$TMP/elsewhere/22222222-2222-3333-4444-555555555555.jsonl" SessionEnd \
    | AIB_LIVE_PID="$HOLDER" "$AIB_BIN" hook end claude >/dev/null 2>&1
[ ! -e "$AIB_ARCHIVE_DIR/.state/22222222-2222-3333-4444-555555555555" ] || fail "path outside projects accepted"
cp "$SRC" "$PROJ/33333333-2222-3333-4444-555555555555.jsonl"
payload 44444444-2222-3333-4444-555555555555 "$PROJ/33333333-2222-3333-4444-555555555555.jsonl" SessionEnd \
    | AIB_LIVE_PID="$HOLDER" "$AIB_BIN" hook end claude >/dev/null 2>&1
[ ! -e "$AIB_ARCHIVE_DIR/.state/44444444-2222-3333-4444-555555555555" ] || fail "uuid/file name mismatch accepted"
ln -s "$SRC" "$PROJ/55555555-2222-3333-4444-555555555555.jsonl"
payload 55555555-2222-3333-4444-555555555555 "$PROJ/55555555-2222-3333-4444-555555555555.jsonl" SessionEnd \
    | AIB_LIVE_PID="$HOLDER" "$AIB_BIN" hook end claude >/dev/null 2>&1
[ ! -e "$AIB_ARCHIVE_DIR/claude/55555555-2222-3333-4444-555555555555.jsonl.gz" ] || fail "symlinked transcript archived"
pass "transcripts outside the projects dir, mismatched names and symlinks are refused"

# --- 6. Busy lock skips; a dead worker's lock is reclaimed -------------------------------
U6="66666666-2222-3333-4444-555555555555"; printf '{"type":"user","cwd":"%s"}\n' "$BR_REAL" > "$PROJ/$U6.jsonl"
"$AIB_BIN" archive backfill >/dev/null 2>&1   # registers + archives
mkdir -p "$AIB_ARCHIVE_DIR/.lock/$U6"; echo "$HOLDER" > "$AIB_ARCHIVE_DIR/.lock/$U6/pid"
printf '{"type":"user","timestamp":"x"}\n' >> "$PROJ/$U6.jsonl"
"$AIB_BIN" archive run "$U6" >/dev/null 2>&1
[ "$(gz_sha "$AIB_ARCHIVE_DIR/claude/$U6.jsonl.gz")" != "$(src_sha "$PROJ/$U6.jsonl")" ] || fail "a live lock holder must not be bypassed"
echo 999999 > "$AIB_ARCHIVE_DIR/.lock/$U6/pid"
"$AIB_BIN" archive run "$U6" >/dev/null 2>&1
[ "$(gz_sha "$AIB_ARCHIVE_DIR/claude/$U6.jsonl.gz")" = "$(src_sha "$PROJ/$U6.jsonl")" ] || fail "dead worker lock not reclaimed"
[ ! -e "$AIB_ARCHIVE_DIR/.lock/$U6" ] || fail "lock left behind"
pass "a live lock is respected; a dead worker's lock is reclaimed"

# --- 7. Backfill: this barrack by default, --all for every project ------------------------
OTHER="$CLAUDE_CONFIG_DIR/projects/-other-project"; mkdir -p "$OTHER"
U7="77777777-2222-3333-4444-555555555555"; printf '{"type":"user","cwd":"/other/project"}\n' > "$OTHER/$U7.jsonl"
U8="88888888-2222-3333-4444-555555555555"; printf '{"type":"user","cwd":"%s"}\n' "$BR_REAL" > "$PROJ/$U8.jsonl"
"$AIB_BIN" archive backfill >/dev/null 2>&1 || fail "backfill failed"
[ -f "$AIB_ARCHIVE_DIR/claude/$U8.jsonl.gz" ] || fail "backfill missed this barrack's transcript"
[ ! -e "$AIB_ARCHIVE_DIR/claude/$U7.jsonl.gz" ] || fail "backfill archived another project without --all"
"$AIB_BIN" archive backfill --all >/dev/null 2>&1
[ -f "$AIB_ARCHIVE_DIR/claude/$U7.jsonl.gz" ] || fail "backfill --all missed another project"
pass "backfill covers this barrack by default and every project with --all"

# --- 8. Source missing and failures are visible in status ---------------------------------
U9="99999999-2222-3333-4444-555555555555"; printf '{"type":"user","cwd":"%s"}\n' "$BR_REAL" > "$PROJ/$U9.jsonl"
payload "$U9" "$PROJ/$U9.jsonl" SessionStart | AIB_ARCHIVE_SYNC=0 AIB_ARCHIVE_NO_WORKER=1 AIB_LIVE_PID="$HOLDER" "$AIB_BIN" hook start claude >/dev/null 2>&1
rm -f "$PROJ/$U9.jsonl"
"$AIB_BIN" archive run "$U9" >/dev/null 2>&1
[ "$(state_of "$U9" state)" = source_missing ] || fail "missing source should be source_missing, got $(state_of "$U9" state)"
st="$("$AIB_BIN" archive status 2>&1)"
echo "$st" | head -1 | grep -q "1 source_missing" || fail "status first line must count source_missing: $(echo "$st" | head -1)"
echo "$st" | grep -qi "plaintext" || fail "status must warn that archives are plaintext"
pass "missing sources are recorded and surfaced in status"

# --- 9. show resolves an aib session id; prune deletes old archives with a log ------------
out9="$("$AIB_BIN" archive show "$SID" 2>&1)"; echo "$out9" | grep -q "$UUID" || fail "show <sid> did not resolve the transcript: $out9"
_ts=$(( $(date +%s) - 400 * 86400 ))
sed -i '' "s/^archived_at=.*/archived_at=$_ts/" "$AIB_ARCHIVE_DIR/.state/$U8" 2>/dev/null || sed -i "s/^archived_at=.*/archived_at=$_ts/" "$AIB_ARCHIVE_DIR/.state/$U8"
"$AIB_BIN" archive prune --older-than 365 >/dev/null 2>&1 || fail "prune failed"
[ ! -e "$AIB_ARCHIVE_DIR/claude/$U8.jsonl.gz" ] || fail "old archive not pruned"
[ -f "$ARC" ] || fail "recent archive must survive prune"
grep -q "$U8" "$AIB_ARCHIVE_DIR/.pruned.log" || fail "prune must be logged"
[ "$(state_of "$U8" state)" = pruned ] || fail "pruned state not recorded"
"$AIB_BIN" archive prune >/dev/null 2>&1 && fail "prune without --older-than must refuse"
pass "show resolves session ids; prune is explicit, logged and age-bounded"

# --- 10. Hook stays fast and never fails when the archive cannot be written ---------------
U10="10101010-2222-3333-4444-555555555555"; printf '{"type":"user","cwd":"%s"}\n' "$BR_REAL" > "$PROJ/$U10.jsonl"
payload "$U10" "$PROJ/$U10.jsonl" SessionStart | AIB_LIVE_PID="$HOLDER" "$AIB_BIN" hook start claude >/dev/null 2>&1
S10="$(cat sessions/.active)"
chmod 500 "$AIB_ARCHIVE_DIR/.state"
t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
payload "$U10" "$PROJ/$U10.jsonl" SessionEnd | AIB_ARCHIVE_SYNC=0 AIB_LIVE_PID="$HOLDER" "$AIB_BIN" hook end claude >/dev/null 2>&1; rc=$?
t1=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
chmod 700 "$AIB_ARCHIVE_DIR/.state"
[ "$rc" = 0 ] || fail "hook end must not fail when the archive is unwritable"
awk -v a="$t0" -v b="$t1" 'BEGIN { exit (b - a < 0.6) ? 0 : 1 }' || fail "hook end too slow for the ~0.9s SessionEnd budget ($t0 → $t1)"
pass "hook end stays under the SessionEnd budget and never fails on archive errors"

echo "All transcript archive tests passed."
