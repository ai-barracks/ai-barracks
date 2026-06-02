#!/usr/bin/env bash
# AIB-002 / AIB-004 regression suite (Batch P0-aib-hooks).
#
# AIB-002: hook event/end MUST resolve the originating agent via the PID -> session
#          mapping under sessions/.live/by-pid/, not the shared sessions/.active
#          marker (which only points at the LATEST start) or the last `${client}-...`
#          row in SESSIONS.md (which is the latest registration). Two concurrent
#          same-client sessions must not trample each other.
#
# AIB-004: `aib start claude` must NOT pre-create a session row / context file /
#          cleanup trap / .active marker — the Claude SessionStart/SessionEnd hooks
#          own that lifecycle now. The optional wrapper task is handed over via
#          AIB_START_TASK and surfaced by cmd_hook_start.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AIB_BIN="${SCRIPT_DIR}/../bin/aib"
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Bring in TEMPLATE_DIR so the fresh barrack can seed SESSIONS.md from template.
AIB_SOURCE_ONLY=1 source "$AIB_BIN"
set +e

# ----- AIB-002: concurrent same-client PID mapping -----
BR1="${TMP}/barrack1"
mkdir -p "$BR1"
(
  cd "$BR1"
  cp "$TEMPLATE_DIR/SESSIONS.md" SESSIONS.md
  mkdir -p sessions

  # Use two REAL background processes so kill -0 keeps reporting alive and
  # `cleanup_stale` (run inside hook start) doesn't reap the sidecars as dead.
  # We deliberately do NOT override AIB_LIVE_LSTART here — _aib_lstart reads
  # the real ps lstart, which stays stable for the life of the sleep process,
  # so the PID map's stored lstart matches the lstart at event/end time too.
  sleep 600 & PID_A=$!
  sleep 600 & PID_B=$!
  trap 'kill "$PID_A" "$PID_B" 2>/dev/null; wait 2>/dev/null' EXIT

  AIB_LIVE_PID="$PID_A" "$AIB_BIN" hook start claude >/dev/null
  sid1="$(cat sessions/.active)"
  AIB_LIVE_PID="$PID_B" "$AIB_BIN" hook start claude >/dev/null
  sid2="$(cat sessions/.active)"

  [ -n "$sid1" ] && [ -n "$sid2" ] && [ "$sid1" != "$sid2" ] \
    || { echo "FAIL: hook start did not produce two distinct sids ($sid1 vs $sid2)"; exit 1; }
  [ "$(cat sessions/.active)" = "$sid2" ] \
    || { echo "FAIL: .active should point at the latest started session ($sid2)"; exit 1; }

  # PID maps must exist for both, each scoped to its own PID.
  [ -f "sessions/.live/by-pid/${PID_A}.json" ] \
    || { echo "FAIL: PID map missing for sid1 (pid $PID_A)"; exit 1; }
  [ -f "sessions/.live/by-pid/${PID_B}.json" ] \
    || { echo "FAIL: PID map missing for sid2 (pid $PID_B)"; exit 1; }
  [ "$(jq -r .session_id "sessions/.live/by-pid/${PID_A}.json")" = "$sid1" ] \
    || { echo "FAIL: PID map for $PID_A points at wrong sid"; exit 1; }
  [ "$(jq -r .session_id "sessions/.live/by-pid/${PID_B}.json")" = "$sid2" ] \
    || { echo "FAIL: PID map for $PID_B points at wrong sid"; exit 1; }

  # `hook event Notification` from sid1's PID must move sid1 -> blocked
  # WITHOUT touching sid2 (the .active marker session). This is the
  # regression: a pre-fix implementation would update sid2's sidecar.
  # We assert on the RAW sidecar `.state` because the fake PIDs aren't running
  # processes, so cmd_session_state would fold them to crashed/interrupted.
  AIB_LIVE_PID="$PID_A" \
    "$AIB_BIN" hook event claude Notification >/dev/null
  s1_state="$(jq -r .state "sessions/.live/${sid1}.status" 2>/dev/null)"
  s2_state="$(jq -r .state "sessions/.live/${sid2}.status" 2>/dev/null)"
  [ "$s1_state" = "blocked" ] \
    || { echo "FAIL: sid1 raw state should be blocked (got '$s1_state'); event leaked to wrong session"; exit 1; }
  [ "$s2_state" = "working" ] \
    || { echo "FAIL: sid2 raw state must remain working (got '$s2_state'); .active fallback used in error"; exit 1; }
  # Belt + suspenders: also check the recorded session_id inside sid1's sidecar
  # — that file alone got the Notification event, not sid2's sidecar.
  s1_event="$(jq -r .event "sessions/.live/${sid1}.status" 2>/dev/null)"
  s2_event="$(jq -r .event "sessions/.live/${sid2}.status" 2>/dev/null)"
  [ "$s1_event" = "Notification" ] \
    || { echo "FAIL: sid1's last event should be Notification (got '$s1_event')"; exit 1; }
  [ "$s2_event" = "SessionStart" ] \
    || { echo "FAIL: sid2's last event must remain SessionStart (got '$s2_event'); event mis-routed"; exit 1; }

  # `hook end claude` from sid1's PID must remove ONLY sid1 from SESSIONS.md,
  # leave sid2's row intact, and leave .active pointing at sid2 (since .active
  # never named sid1 in the first place).
  AIB_LIVE_PID="$PID_A" \
    "$AIB_BIN" hook end claude >/dev/null
  grep -q "^| ${sid1} " SESSIONS.md \
    && { echo "FAIL: SESSIONS.md still contains sid1 after hook end"; exit 1; }
  grep -q "^| ${sid2} " SESSIONS.md \
    || { echo "FAIL: SESSIONS.md missing sid2 after hook end for sid1"; exit 1; }
  [ -f sessions/.active ] \
    || { echo "FAIL: sessions/.active was deleted even though it pointed at sid2"; exit 1; }
  [ "$(cat sessions/.active)" = "$sid2" ] \
    || { echo "FAIL: sessions/.active no longer equals sid2 ($(cat sessions/.active))"; exit 1; }
  # sid1's PID mapping cleared; sid2's preserved.
  [ ! -f "sessions/.live/by-pid/${PID_A}.json" ] \
    || { echo "FAIL: sid1's PID map should have been removed"; exit 1; }
  [ -f "sessions/.live/by-pid/${PID_B}.json" ] \
    || { echo "FAIL: sid2's PID map must remain after sid1 ends"; exit 1; }
) || exit 1
pass "AIB-002: concurrent same-client PID routing (event + end target the right sid)"

# ----- AIB-002 legacy fallback: no PID mapping -> .active is honored (back-compat) -----
BR2="${TMP}/barrack2"
mkdir -p "$BR2"
(
  cd "$BR2"
  cp "$TEMPLATE_DIR/SESSIONS.md" SESSIONS.md
  mkdir -p sessions sessions/.live
  legacy_sid="claude-20260601-120000-legacy01"
  # Simulate a pre-upgrade session: row + .active but NO by-pid map.
  printf '| %s | Claude Code | 06-01 12:00 | 06-01 12:00 | (starting) |\n' "$legacy_sid" >> SESSIONS.md
  echo "$legacy_sid" > sessions/.active

  # A PID with no mapping should fall back to .active and update the legacy sid.
  AIB_LIVE_PID=999999 AIB_LIVE_LSTART="Mon Jan  1 00:00:00 2099" \
    "$AIB_BIN" hook event claude Notification >/dev/null
  st="$("$AIB_BIN" sessions state "$legacy_sid")"
  # PID 999999 is dead, so effective state for blocked = crashed; the key check
  # is that the legacy session's sidecar got written at all (it didn't before).
  [ -f "sessions/.live/${legacy_sid}.status" ] \
    || { echo "FAIL: legacy fallback did not write a sidecar for $legacy_sid"; exit 1; }
  [ "$(jq -r .state "sessions/.live/${legacy_sid}.status")" = "blocked" ] \
    || { echo "FAIL: legacy fallback did not mark $legacy_sid blocked"; exit 1; }
) || exit 1
pass "AIB-002: legacy .active fallback preserved when no PID mapping exists"

# ----- AIB-002 invalid-map safety: stale/wrong-client maps MUST NOT trigger .active fallback -----
# A PID map that exists but is unusable (lstart mismatch from PID reuse, or
# .client recorded as a different agent, or corrupt JSON) used to fall through
# the resolver's empty-echo path. cmd_hook_event/cmd_hook_end then treated it as
# "no mapping" and read .active / last SESSIONS row instead — quietly mis-routing
# the event into whatever live session happened to be the latest start. The
# resolver now returns a distinct invalid-map status; hooks no-op in that case.
BR4="${TMP}/barrack4"
mkdir -p "$BR4"
(
  cd "$BR4"
  cp "$TEMPLATE_DIR/SESSIONS.md" SESSIONS.md
  mkdir -p sessions

  sleep 600 & PID_A=$!
  sleep 600 & PID_B=$!
  trap 'kill "$PID_A" "$PID_B" 2>/dev/null; wait 2>/dev/null' EXIT

  AIB_LIVE_PID="$PID_A" "$AIB_BIN" hook start claude >/dev/null
  sid1="$(cat sessions/.active)"
  AIB_LIVE_PID="$PID_B" "$AIB_BIN" hook start claude >/dev/null
  sid2="$(cat sessions/.active)"

  [ -n "$sid1" ] && [ -n "$sid2" ] && [ "$sid1" != "$sid2" ] \
    || { echo "FAIL: setup did not produce two distinct sids"; exit 1; }
  [ "$(cat sessions/.active)" = "$sid2" ] \
    || { echo "FAIL: .active must point at sid2 (latest start)"; exit 1; }

  map_a="sessions/.live/by-pid/${PID_A}.json"
  [ -f "$map_a" ] || { echo "FAIL: PID map for sid1 missing"; exit 1; }

  # --- Case 1: stale lstart (PID reuse simulation) ---
  tmpf="$(mktemp)"
  jq '.lstart = "Tue Jan  1 00:00:00 1970"' "$map_a" > "$tmpf" && mv "$tmpf" "$map_a"

  AIB_LIVE_PID="$PID_A" \
    "$AIB_BIN" hook event claude Notification >/dev/null 2>&1
  # sid2 must be untouched — no .active fallback occurred.
  s2_state="$(jq -r .state "sessions/.live/${sid2}.status" 2>/dev/null)"
  s2_event="$(jq -r .event "sessions/.live/${sid2}.status" 2>/dev/null)"
  [ "$s2_state" = "working" ] && [ "$s2_event" = "SessionStart" ] \
    || { echo "FAIL: stale-lstart map leaked Notification into sid2 (state=$s2_state event=$s2_event)"; exit 1; }
  # sid1 must also be unchanged — the invalid map should not let us "guess" sid1.
  s1_state="$(jq -r .state "sessions/.live/${sid1}.status" 2>/dev/null)"
  s1_event="$(jq -r .event "sessions/.live/${sid1}.status" 2>/dev/null)"
  [ "$s1_state" = "working" ] && [ "$s1_event" = "SessionStart" ] \
    || { echo "FAIL: stale-lstart map still wrote sid1 instead of no-op (state=$s1_state event=$s1_event)"; exit 1; }

  # --- Case 2: wrong-client (map says codex, hook says claude) ---
  # Restore lstart so client is the ONLY corruption this time, isolating that check.
  cur_lstart="$(ps -o lstart= -p "$PID_A" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//')"
  jq --arg ls "$cur_lstart" '.lstart = $ls | .client = "codex"' "$map_a" > "$tmpf" && mv "$tmpf" "$map_a"

  AIB_LIVE_PID="$PID_A" \
    "$AIB_BIN" hook event claude Notification >/dev/null 2>&1
  s2_state="$(jq -r .state "sessions/.live/${sid2}.status" 2>/dev/null)"
  s2_event="$(jq -r .event "sessions/.live/${sid2}.status" 2>/dev/null)"
  [ "$s2_state" = "working" ] && [ "$s2_event" = "SessionStart" ] \
    || { echo "FAIL: wrong-client map leaked Notification into sid2 (state=$s2_state event=$s2_event)"; exit 1; }

  # --- Case 3: hook end with the same invalid map must not strip sid2 ---
  rows_before="$(grep -c '^| claude-' SESSIONS.md || true)"
  AIB_LIVE_PID="$PID_A" \
    "$AIB_BIN" hook end claude >/dev/null 2>&1
  rows_after="$(grep -c '^| claude-' SESSIONS.md || true)"
  [ "$rows_before" = "$rows_after" ] \
    || { echo "FAIL: hook end with invalid map mutated SESSIONS.md (${rows_before} -> ${rows_after})"; exit 1; }
  grep -q "^| ${sid2} " SESSIONS.md \
    || { echo "FAIL: hook end with invalid map removed sid2 from SESSIONS.md"; exit 1; }
  [ -f sessions/.active ] && [ "$(cat sessions/.active)" = "$sid2" ] \
    || { echo "FAIL: hook end with invalid map disturbed .active (now: $(cat sessions/.active 2>/dev/null))"; exit 1; }
) || exit 1
pass "AIB-002: stale/wrong-client PID maps no-op (no .active fallback to wrong session)"

# ----- AIB-004: `aib start claude` is hook-owned (no duplicate row/file) -----
BR3="${TMP}/barrack3"
mkdir -p "$BR3"
(
  cd "$BR3"
  cp "$TEMPLATE_DIR/SESSIONS.md" SESSIONS.md
  mkdir -p sessions

  # Stub `claude` earlier in PATH. The stub mimics the real Claude CLI's hook
  # lifecycle: SessionStart -> SessionEnd, with deterministic AIB_LIVE_PID/LSTART
  # so the wrapper's `exec claude` produces exactly one session via hooks.
  STUB_DIR="${TMP}/stub-bin-3"
  mkdir -p "$STUB_DIR"
  cat > "${STUB_DIR}/claude" <<EOSTUB
#!/usr/bin/env bash
set -u
# AIB_BIN injected by the test so the stub can call the real aib hooks.
export AIB_LIVE_PID="\${AIB_LIVE_PID:-333333}"
export AIB_LIVE_LSTART="\${AIB_LIVE_LSTART:-Tue Jun  2 10:00:00 2026}"
"\$AIB_BIN" hook start claude >/dev/null
"\$AIB_BIN" hook end claude >/dev/null
exit 0
EOSTUB
  chmod +x "${STUB_DIR}/claude"

  AIB_BIN="$AIB_BIN" PATH="${STUB_DIR}:${PATH}" \
    AIB_LIVE_PID=333333 AIB_LIVE_LSTART="Tue Jun  2 10:00:00 2026" \
    "$AIB_BIN" start claude "wrapper task" >/dev/null 2>&1 \
    || { echo "FAIL: aib start claude (hook-owned wrapper) returned nonzero"; exit 1; }

  # Exactly one session context file must exist — the one created by the hook,
  # NOT a duplicate created by the wrapper before exec.
  shopt -s nullglob
  ctx_files=(sessions/claude-*.md)
  shopt -u nullglob
  [ "${#ctx_files[@]}" = "1" ] \
    || { echo "FAIL: expected exactly 1 claude session file, got ${#ctx_files[@]}: ${ctx_files[*]}"; exit 1; }

  # The hook honored AIB_START_TASK from the wrapper for the Task field.
  task_line="$(grep '^- \*\*Task\*\*:' "${ctx_files[0]}" || true)"
  echo "$task_line" | grep -q 'wrapper task' \
    || { echo "FAIL: ctx file Task field missing wrapper task: $task_line"; exit 1; }

  # hook end finalized: no leftover .active marker; no leftover session row.
  [ ! -f sessions/.active ] \
    || { echo "FAIL: sessions/.active should not remain after hook end"; exit 1; }
  if grep -q "^| claude-" SESSIONS.md; then
    echo "FAIL: SESSIONS.md still has a claude- row after hook end:"
    grep "^| claude-" SESSIONS.md
    exit 1
  fi
) || exit 1
pass "AIB-004: aib start claude is hook-owned (single session row from hooks, AIB_START_TASK respected, clean state on end)"

echo "ALL PASS (test_hook_pid_routing.sh)"
