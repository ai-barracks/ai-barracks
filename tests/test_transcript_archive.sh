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

# --- 5. Path validation (through the hook entry point, with a positive control) --------
hook_end_direct() {  # hook_end_direct <uuid> <path>: run the SessionEnd archive hook in-process
    _ARCH_PAYLOAD="$(payload "$1" "$2" SessionEnd)"; _ARCH_END_DONE=""
    _arch_hook SessionEnd "" >/dev/null 2>&1
}
UOK="12121212-2222-3333-4444-555555555555"; cp "$SRC" "$PROJ/$UOK.jsonl"
hook_end_direct "$UOK" "$PROJ/$UOK.jsonl"
[ -f "$AIB_ARCHIVE_DIR/claude/$UOK.jsonl.gz" ] || fail "positive control: valid transcript not archived"
mkdir -p "$TMP/elsewhere"; U5A="22222222-2222-3333-4444-555555555555"; cp "$SRC" "$TMP/elsewhere/$U5A.jsonl"
hook_end_direct "$U5A" "$TMP/elsewhere/$U5A.jsonl"
U5B="44444444-2222-3333-4444-555555555555"; cp "$SRC" "$PROJ/33333333-2222-3333-4444-555555555555.jsonl"
hook_end_direct "$U5B" "$PROJ/33333333-2222-3333-4444-555555555555.jsonl"
U5C="55555555-2222-3333-4444-555555555555"; ln -s "$SRC" "$PROJ/$U5C.jsonl"
hook_end_direct "$U5C" "$PROJ/$U5C.jsonl"
U5D="56565656-2222-3333-4444-555555555555"; mkdir -p "$PROJ/nested"; cp "$SRC" "$PROJ/nested/$U5D.jsonl"
hook_end_direct "$U5D" "$PROJ/nested/$U5D.jsonl"
for u in "$U5A" "$U5B" "$U5C" "$U5D"; do
    [ ! -e "$AIB_ARCHIVE_DIR/.state/$u" ] && ! ls "$AIB_ARCHIVE_DIR/.intent/$u."* >/dev/null 2>&1 \
        && [ ! -e "$AIB_ARCHIVE_DIR/claude/$u.jsonl.gz" ] || fail "invalid transcript accepted: $u"
done
pass "outside paths, name mismatches, symlinks and nested dirs are refused; a valid path is archived"

# --- 6. Busy lock skips; a dead worker's lock is reclaimed -------------------------------
U6="66666666-2222-3333-4444-555555555555"; printf '{"type":"user","cwd":"%s"}\n' "$BR_REAL" > "$PROJ/$U6.jsonl"
"$AIB_BIN" archive backfill >/dev/null 2>&1   # registers + archives
mkdir -p "$AIB_ARCHIVE_DIR/.lock/$U6"; echo "$HOLDER|$(_arch_proc_start "$HOLDER")|live" > "$AIB_ARCHIVE_DIR/.lock/$U6/owner"
touch -t 202001010000 "$AIB_ARCHIVE_DIR/.lock/$U6"   # an old lock of a live owner must still be respected
printf '{"type":"user","timestamp":"x"}\n' >> "$PROJ/$U6.jsonl"
"$AIB_BIN" archive run "$U6" >/dev/null 2>&1
[ "$(gz_sha "$AIB_ARCHIVE_DIR/claude/$U6.jsonl.gz")" != "$(src_sha "$PROJ/$U6.jsonl")" ] || fail "a live lock holder must not be bypassed"
echo "999999||dead" > "$AIB_ARCHIVE_DIR/.lock/$U6/owner"
"$AIB_BIN" archive run "$U6" >/dev/null 2>&1
[ "$(gz_sha "$AIB_ARCHIVE_DIR/claude/$U6.jsonl.gz")" = "$(src_sha "$PROJ/$U6.jsonl")" ] || fail "dead worker lock not reclaimed"
[ ! -e "$AIB_ARCHIVE_DIR/.lock/$U6" ] || fail "lock left behind"
echo "$HOLDER|Mon Jan  1 00:00:00 2001|reused" > "$AIB_ARCHIVE_DIR/.lock/$U6/owner"   # pid reused by another process
printf '{"type":"user","timestamp":"y"}\n' >> "$PROJ/$U6.jsonl"
"$AIB_BIN" archive run "$U6" >/dev/null 2>&1
[ "$(gz_sha "$AIB_ARCHIVE_DIR/claude/$U6.jsonl.gz")" = "$(src_sha "$PROJ/$U6.jsonl")" ] || fail "lock of a reused pid not reclaimed"
pass "a live owner is never reclaimed by age; dead or reused-pid locks are reclaimed"

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

# --- 10. Hook stays fast and never fails when the archive cannot be written -------------
U10="10101010-2222-3333-4444-555555555555"; printf '{"type":"user","cwd":"%s"}\n' "$BR_REAL" > "$PROJ/$U10.jsonl"
mkdir -p "$TMP/ro"; chmod 500 "$TMP/ro"
payload "$U10" "$PROJ/$U10.jsonl" SessionStart | AIB_ARCHIVE_DIR="$TMP/ro/archive" AIB_LIVE_PID="$HOLDER" "$AIB_BIN" hook start claude >/dev/null 2>&1 \
    || fail "hook start must not fail when the archive is unwritable"
t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
payload "$U10" "$PROJ/$U10.jsonl" SessionEnd | AIB_ARCHIVE_DIR="$TMP/ro/archive" AIB_LIVE_PID="$HOLDER" "$AIB_BIN" hook end claude >/dev/null 2>&1; rc=$?
t1=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
[ ! -e "$TMP/ro/archive" ] || fail "test setup: archive dir should not be creatable"
chmod 700 "$TMP/ro"
[ "$rc" = 0 ] || fail "hook end must not fail when the archive is unwritable"
awk -v a="$t0" -v b="$t1" 'BEGIN { exit (b - a < 0.6) ? 0 : 1 }' || fail "hook end too slow for the ~0.9s SessionEnd budget ($t0 → $t1)"
pass "hook start/end stay fast and succeed when the archive cannot be written"

# --- 11. Real detached worker: the hook returns, the worker finishes afterwards ------------
U11="11111111-aaaa-3333-4444-555555555555"; cp "$SRC" "$PROJ/$U11.jsonl"
payload "$U11" "$PROJ/$U11.jsonl" SessionEnd | AIB_ARCHIVE_SYNC=0 AIB_LIVE_PID="$HOLDER" "$AIB_BIN" hook end claude >/dev/null 2>&1
for _ in $(seq 1 50); do [ "$(state_of "$U11" state)" = succeeded ] && break; sleep 0.2; done
[ "$(state_of "$U11" state)" = succeeded ] && [ -f "$AIB_ARCHIVE_DIR/claude/$U11.jsonl.gz" ] \
    || fail "detached worker did not archive after the hook returned (state=$(state_of "$U11" state))"
pass "a detached worker archives after SessionEnd returns, even without a session row"

# --- 12. Concurrent workers on one uuid leave one verified archive ------------------------
printf '{"type":"user","timestamp":"2026-10-16T03:00:00Z","message":{"content":"more"}}\n' >> "$PROJ/$U11.jsonl"
pids=""; for _ in 1 2 3 4 5; do "$AIB_BIN" archive run "$U11" >/dev/null 2>&1 & pids="$pids $!"; done
for p in $pids; do wait "$p"; done   # not a bare wait: HOLDER is a background job too
"$AIB_BIN" archive run "$U11" >/dev/null 2>&1
[ "$(gz_sha "$AIB_ARCHIVE_DIR/claude/$U11.jsonl.gz")" = "$(src_sha "$PROJ/$U11.jsonl")" ] || fail "concurrent runs corrupted the archive"
[ "$(ls "$AIB_ARCHIVE_DIR/claude" | grep -c "^$U11")" = 1 ] || fail "concurrent runs created variants"
[ ! -e "$AIB_ARCHIVE_DIR/.lock/$U11" ] && ! ls "$AIB_ARCHIVE_DIR/claude/.tmp.$U11."* >/dev/null 2>&1 || fail "lock or tmp left behind"
pass "concurrent workers converge on one verified archive"

# --- 13. Same-length rewrite, deleted archive and failed digest are all repaired ----------
U13="13131313-2222-3333-4444-555555555555"; printf '{"type":"user","cwd":"%s","message":{"content":"AAAA"}}\n' "$BR_REAL" > "$PROJ/$U13.jsonl"
"$AIB_BIN" archive backfill >/dev/null 2>&1
printf '{"type":"user","cwd":"%s","message":{"content":"BBBB"}}\n' "$BR_REAL" > "$PROJ/$U13.jsonl"
"$AIB_BIN" archive run "$U13" >/dev/null 2>&1
[ "$(ls "$AIB_ARCHIVE_DIR/claude" | grep -c "^$U13\.[0-9a-f]")" = 1 ] || fail "same-length rewrite not detected"
rm -f "$AIB_ARCHIVE_DIR/claude/$U13.jsonl.gz"; _sed_inplace "$AIB_ARCHIVE_DIR/.state/$U13" -e 's/^archive=.*/archive='"$U13"'.jsonl.gz/'
"$AIB_BIN" archive run "$U13" >/dev/null 2>&1
ls "$AIB_ARCHIVE_DIR/claude/$U13"* >/dev/null 2>&1 && [ "$(state_of "$U13" state)" = succeeded ] || fail "deleted archive not restored"
_sed_inplace "$AIB_ARCHIVE_DIR/.state/$U13" -e 's/^digest_state=.*/digest_state=failed/'
rm -f "$AIB_ARCHIVE_DIR/.digest/$U13.json"
"$AIB_BIN" archive run "$U13" >/dev/null 2>&1
[ -f "$AIB_ARCHIVE_DIR/.digest/$U13.json" ] && [ "$(state_of "$U13" digest_state)" = ok ] || fail "failed digest not retried"
pass "same-length rewrites, lost archives and failed digests are repaired on the next run"

# --- 14. Digest copies only well-formed metadata ------------------------------------------
U14="14141414-2222-3333-4444-555555555555"
cat > "$PROJ/$U14.jsonl" <<JSON
{"type":"user","cwd":"$BR_REAL","timestamp":{"prompt":"SECRET-TS"},"message":{"content":"hi"}}
{"type":"assistant","timestamp":"2026-10-16T04:00:00Z","message":{"id":"x","model":"SECRET MODEL /etc/passwd","content":[{"type":"tool_use","name":"SECRET tool/../x"}],"usage":{"input_tokens":"lots"}}}
JSON
"$AIB_BIN" archive backfill >/dev/null 2>&1
D14="$AIB_ARCHIVE_DIR/.digest/$U14.json"
grep -q SECRET "$D14" && { cat "$D14"; fail "digest copied malformed values verbatim"; }
jq -e '.models == ["other"] and .tool_calls.other == 1 and .first_ts == "2026-10-16T04:00:00Z" and .tokens.input == 0' "$D14" >/dev/null \
    || { cat "$D14"; fail "digest sanitization"; }
pass "digest keeps only well-formed timestamps and identifiers"

# --- 15. status survives failures listed last; state rejects line breaks -------------------
_arch_state_set "$U14" "cwd=$(printf 'a\nstate=pruned')" && fail "state accepted a line break"
UF="15151515-2222-3333-4444-555555555555"; mkdir -p "$AIB_ARCHIVE_DIR/.state"
printf 'state=failed\nlast_error=x\nattempts=5\n' > "$AIB_ARCHIVE_DIR/.state/$UF"
"$AIB_BIN" archive status >/dev/null 2>&1 || fail "status must exit 0 with failed entries"
pass "status exits 0 with failures; state values cannot carry line breaks"

# --- 16. A writer that never closes stdin cannot stall SessionEnd --------------------------
U16="16161616-2222-3333-4444-555555555555"; cp "$SRC" "$PROJ/$U16.jsonl"
t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
{ payload "$U16" "$PROJ/$U16.jsonl" SessionEnd; sleep 3; } | {
    AIB_ARCHIVE_NO_WORKER=1 AIB_LIVE_PID="$HOLDER" "$AIB_BIN" hook end claude >/dev/null 2>&1
    perl -MTime::HiRes=time -e 'printf "%.3f", time' > "$TMP/t16"; }
t1="$(cat "$TMP/t16")"
awk -v a="$t0" -v b="$t1" 'BEGIN { exit (b - a < 0.6) ? 0 : 1 }' || fail "open stdin stalled hook end ($t0 → $t1)"
ls "$AIB_ARCHIVE_DIR/.intent/$U16."* >/dev/null 2>&1 || fail "payload from an open stdin was not used"
pass "hook end reads a complete payload without waiting for EOF"
# --- 17. Split payload delivery is read whole --------------------------------------------
U17="17171717-2222-3333-4444-555555555555"; cp "$SRC" "$PROJ/$U17.jsonl"
full="$(payload "$U17" "$PROJ/$U17.jsonl" SessionEnd)"
{ printf '%s' "${full:0:20}"; sleep 0.1; printf '%s' "${full:20}"; } \
    | AIB_ARCHIVE_NO_WORKER=1 AIB_LIVE_PID="$HOLDER" "$AIB_BIN" hook end claude >/dev/null 2>&1
ls "$AIB_ARCHIVE_DIR/.intent/$U17."* >/dev/null 2>&1 || fail "payload delivered in two writes was cut short"
pass "a payload delivered in pieces is read until it parses"

# --- 18. verify catches a damaged archive; a stale prefix cache cannot cause loss --------
"$AIB_BIN" archive run "$U17" >/dev/null 2>&1
"$AIB_BIN" archive verify >/dev/null 2>&1 || fail "verify should pass on healthy archives"
A17="$AIB_ARCHIVE_DIR/claude/$U17.jsonl.gz"; cp "$A17" "$TMP/a17.bak"
printf 'garbage' >> "$A17"
"$AIB_BIN" archive verify >/dev/null 2>&1 && fail "verify must report a damaged archive"
cp "$TMP/a17.bak" "$A17"
# State claims an older prefix than the archive really holds; the decision must use the file.
printf '{"type":"user","timestamp":"2026-10-16T05:00:00Z","message":{"content":"B-part"}}\n' >> "$PROJ/$U17.jsonl"
"$AIB_BIN" archive run "$U17" >/dev/null 2>&1        # archive now holds ...+B
sed -i '' '$d' "$PROJ/$U17.jsonl" 2>/dev/null || sed -i '$d' "$PROJ/$U17.jsonl"
printf '{"type":"user","timestamp":"2026-10-16T05:00:01Z","message":{"content":"C-part"}}\n' >> "$PROJ/$U17.jsonl"
"$AIB_BIN" archive run "$U17" >/dev/null 2>&1        # source is ...+C: not an extension of ...+B
gzip -dc "$A17" | grep -q "B-part" || fail "the B part was lost from the main archive"
ls "$AIB_ARCHIVE_DIR/claude/$U17."*.jsonl.gz 2>/dev/null | grep -v "/$U17.jsonl.gz" | xargs gzip -dc 2>/dev/null | grep -q "C-part" \
    || fail "the C rewrite was not kept as a variant"
pass "verify detects damage; a rewrite never replaces content the archive already holds"
echo "All transcript archive tests passed."
