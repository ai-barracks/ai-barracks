#!/usr/bin/env bash
# Session seals: ended (RECORD) session files get a sha256 seal at SessionEnd, and
# later changes are reported (SessionStart injection + `aib sessions verify`) until
# the user approves them with `aib sessions seal <id>`. Seals are never overwritten
# automatically, so resuming or re-ending a session cannot launder an unapproved
# change. Not a security boundary — a writer replacing both file and seal is unseen.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AIB_BIN="${SCRIPT_DIR}/../bin/aib"
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

TMP="$(mktemp -d)"
sleep 600 & HOLDER=$!
trap 'kill "$HOLDER" 2>/dev/null; wait 2>/dev/null; rm -rf "$TMP"' EXIT

AIB_SOURCE_ONLY=1 source "$AIB_BIN"
set +e

BR="${TMP}/barrack"
mkdir -p "$BR/sessions"
cp "$TEMPLATE_DIR/SESSIONS.md" "$BR/SESSIONS.md"
cd "$BR" || fail "cd barrack"
touch AGENTS.md   # native Codex hooks only act inside a barrack

start_session() { AIB_LIVE_PID="$HOLDER" "$AIB_BIN" hook start claude 2>/dev/null; }
end_session()   { AIB_LIVE_PID="$HOLDER" "$AIB_BIN" hook end claude >/dev/null 2>&1; }
verify()        { "$AIB_BIN" sessions verify "$@" 2>/dev/null; }

# A session with real work: Task set + one Log line (so hook end keeps the file).
start_session >/dev/null
SID="$(cat sessions/.active)"
MD="sessions/${SID}.md"
SEAL="sessions/.seals/${SID}.sha256"
_sed_inplace "$MD" -e 's/^- \*\*Task\*\*: (pending)/- **Task**: seal fixture/'
printf -- '- [10:00] did work → done\n' >> "$MD"
end_session

# --- 1. SessionEnd seals the final content in shasum format --------------------
[ -f "$SEAL" ] || fail "no seal written at session end"
grep -Eq "^[0-9a-f]{64}  ${MD}\$" "$SEAL" || fail "seal format: $(cat "$SEAL")"
[ "$(wc -l < "$SEAL" | tr -d ' ')" = 1 ] || fail "seal must be a single record"
(shasum -a 256 -c "$SEAL" >/dev/null 2>&1) || fail "seal is not shasum -c compatible"
verify >/dev/null || fail "verify should pass right after end"
pass "SessionEnd writes a shasum-compatible seal of the final file"

# --- 2. Content change with preserved mtime is still detected ------------------
cp -p "$MD" "${TMP}/orig.md"
printf -- '- [11:00] edited after end\n' >> "$MD"
touch -r "${TMP}/orig.md" "$MD"   # defeat any mtime-based shortcut
out="$(verify)"; rc=$?
[ "$rc" = 1 ] || fail "verify exit after modification: $rc"
echo "$out" | grep -q "^modified ${SID}\$" || fail "verify output: $out"
inj="$(start_session)"
NEXT_SID="$(cat sessions/.active)"
echo "$inj" | grep -q "\[AIB INTEGRITY\].*${SID}" || fail "SessionStart did not report the change: $inj"
echo "$inj" | grep -q "aib sessions seal" && fail "injection must not advertise the approval command"
end_session   # NEXT session: pending + no log → deleted, never sealed
[ ! -f "sessions/${NEXT_SID}.md" ] || fail "empty session should be deleted at end"
[ ! -f "sessions/.seals/${NEXT_SID}.sha256" ] || fail "empty session must not be sealed"
pass "modification (same mtime) reported by verify and SessionStart; empty session not sealed"

# --- 3. User approval re-seals; touch-only changes are not reported ------------
"$AIB_BIN" sessions seal "$SID" >/dev/null 2>&1 || fail "seal approval failed"
verify >/dev/null || fail "verify should pass after approval"
touch "$MD"
verify >/dev/null || fail "touch without content change must not be reported"
start_session | grep -q "AIB INTEGRITY" && fail "SessionStart still reports after approval"
end_session
pass "aib sessions seal approves; mtime-only touch is not a change"

# --- 4. Deletion is reported; approving a deletion drops the seal ---------------
mv "$MD" "${TMP}/moved.md"
out="$(verify)"; rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -q "^deleted ${SID}\$" || fail "deleted not reported (rc=$rc): $out"
"$AIB_BIN" sessions seal "$SID" >/dev/null 2>&1 || fail "approving deletion failed"
[ ! -e "$SEAL" ] || fail "seal should be removed after approving deletion"
verify >/dev/null || fail "verify should pass after approving deletion"
mv "${TMP}/moved.md" "$MD"
pass "deleted session file reported, approval removes its seal"

# --- 5. Malformed seals are invalid (exit 2), never silently unsealed ------------
"$AIB_BIN" sessions seal "$SID" >/dev/null 2>&1 || fail "re-seal restored file"
cp "$SEAL" "${TMP}/good.seal"
echo "garbage" > "$SEAL"
out="$(verify)"; rc=$?
[ "$rc" = 2 ] && echo "$out" | grep -q "^invalid ${SID}\$" || fail "garbage seal (rc=$rc): $out"
sed "s|  sessions/.*|  sessions/other.md|" "${TMP}/good.seal" > "$SEAL"
out="$(verify)"; rc=$?
[ "$rc" = 2 ] && echo "$out" | grep -q "^invalid ${SID}\$" || fail "path-mismatch seal (rc=$rc): $out"
cp "${TMP}/good.seal" "$SEAL"
pass "malformed or path-mismatched seals are invalid (exit 2)"

# --- 6. seal refuses active sessions and unsafe ids ------------------------------
start_session >/dev/null
ACTIVE_SID="$(cat sessions/.active)"
"$AIB_BIN" sessions seal "$ACTIVE_SID" >/dev/null 2>&1 && fail "sealing an active session must fail"
[ ! -e "sessions/.seals/${ACTIVE_SID}.sha256" ] || fail "active session got a seal"
"$AIB_BIN" sessions seal "../escape" >/dev/null 2>&1 && fail "unsafe id accepted"
"$AIB_BIN" sessions seal ".." >/dev/null 2>&1 && fail "dot id accepted"
end_session
pass "seal refuses active sessions and unsafe ids"

# --- 7. Native Codex: end seals; resume releases only an intact seal ------------
native() { jq -n --arg e "$1" --arg s "$2" '{hook_event_name:$e,session_id:$s}' \
    | AIB_LIVE_PID="$HOLDER" "$AIB_BIN" hook native codex >/dev/null 2>&1; }
native SessionStart thread-a
NSID="$(ls sessions/codex-native-*.md | head -1 | xargs basename | sed 's/\.md$//')"
NMD="sessions/${NSID}.md"; NSEAL="sessions/.seals/${NSID}.sha256"
native SessionEnd thread-a
[ -f "$NSEAL" ] || fail "native SessionEnd did not seal"
native SessionStart thread-a   # resume of an intact session
grep -q '^- \*\*Status\*\*: active' "$NMD" || fail "native resume did not reactivate"
[ ! -e "$NSEAL" ] || fail "resume should release an intact seal"
printf -- '- [12:00] resumed work\n' >> "$NMD"
native SessionEnd thread-a
[ -f "$NSEAL" ] && verify >/dev/null || fail "re-ended native session should be sealed and intact"
printf -- '- [13:00] unapproved edit\n' >> "$NMD"
native SessionStart thread-a   # resume over an unapproved change keeps the old seal
[ -f "$NSEAL" ] || fail "resume must keep the seal of a modified session"
native SessionEnd thread-a
out="$(verify)"; [ $? = 1 ] && echo "$out" | grep -q "^modified ${NSID}\$" \
    || fail "unapproved change was laundered by resume/end: $out"
"$AIB_BIN" sessions seal "$NSID" >/dev/null 2>&1 || fail "approve native session"
pass "native Codex: end seals, resume releases only intact seals, no laundering"

# --- 8. clean deletes empty sealed sessions only when intact --------------------
native SessionStart thread-empty
ESID="$(ls -t sessions/codex-native-*.md | head -1 | xargs basename | sed 's/\.md$//')"
[ "$ESID" != "$NSID" ] || fail "expected a second native session"
native SessionEnd thread-empty
[ -f "sessions/.seals/${ESID}.sha256" ] || fail "empty native session should be sealed"
printf '\nnote\n' >> "sessions/${ESID}.md"   # still pending/no log, but changed
"$AIB_BIN" sessions clean >/dev/null 2>&1
[ -f "sessions/${ESID}.md" ] || fail "clean deleted a modified sealed session"
"$AIB_BIN" sessions seal "$ESID" >/dev/null 2>&1 || fail "approve empty native session"
"$AIB_BIN" sessions clean >/dev/null 2>&1
[ ! -e "sessions/${ESID}.md" ] && [ ! -e "sessions/.seals/${ESID}.sha256" ] \
    || fail "clean should remove an intact empty session together with its seal"
pass "clean skips changed sealed sessions and removes intact ones with their seal"

echo "All session seal tests passed."
