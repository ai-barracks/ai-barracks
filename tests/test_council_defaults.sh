#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

cat > "$TMP/claude" <<'SH'
#!/usr/bin/env bash
echo "CLAUDE_ARGS:$*" >> "${COUNCIL_STUB_CALLS:?}"
printf '%s\n' '{"type": "result", "subtype": "success", "is_error": false, "result": "Claude stub response has enough words to satisfy validation. It confirms the council path can call Claude with model and effort arguments safely.", "usage": {"input_tokens": 12, "output_tokens": 34, "cache_read_input_tokens": 5}}'
SH

cat > "$TMP/codex" <<'SH'
#!/usr/bin/env bash
echo "CODEX_ARGS:$*" >> "${COUNCIL_STUB_CALLS:?}"
printf '%s\n' '{"type": "item.completed", "item": {"type": "agent_message", "text": "Codex stub response has enough words to satisfy validation. It confirms the council path can call Codex with model and reasoning effort safely."}}' '{"type": "turn.completed", "usage": {"input_tokens": 23, "output_tokens": 45, "cached_input_tokens": 7}}'
SH

# Avoid real macOS Keychain / network quota lookup during tests.
cat > "$TMP/security" <<'SH'
#!/usr/bin/env bash
exit 1
SH

chmod +x "$TMP/claude" "$TMP/codex" "$TMP/security"
export COUNCIL_STUB_CALLS="$TMP/calls.log"

before_sleeps="$TMP/before_sleeps"
after_sleeps="$TMP/after_sleeps"
ps -axo pid,comm,args | awk '$2 == "sleep" && $3 == "300" {print $1}' | sort > "$before_sleeps"

PATH="$TMP:$PATH" "$ROOT/scripts/council.sh" -r 1 --consensus 0 --json "smoke test topic" \
    > "$TMP/out.json" 2> "$TMP/err.log" &
pid=$!

for _ in $(seq 1 10); do
    if ! kill -0 "$pid" 2>/dev/null; then
        break
    fi
    sleep 1
done

if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    pkill -P "$pid" 2>/dev/null || true
    fail "council --json smoke did not finish within 10s"
fi

wait "$pid" || fail "council --json smoke exited non-zero"

jq -e '
    .status == "completed"
    and .config.agents.claude.enabled == true
    and .config.agents.claude.model == "runtime-default"
    and .config.agents.claude.effort == "runtime-default"
    and .config.agents.gemini.enabled == false
    and .config.agents.codex.enabled == true
    and .config.agents.codex.model == "runtime-default"
    and .config.agents.codex.effort == "runtime-default"
' "$TMP/out.json" >/dev/null || fail "manifest does not contain expected council defaults"

jq -e '.rounds_data[0].agents.claude.tokens.total == 51 and .rounds_data[0].agents.codex.tokens.total == 68' "$TMP/out.json" >/dev/null || fail "per-call usage missing/wrong"

if grep -q -- '--model\|--effort\|model_reasoning_effort=' "$COUNCIL_STUB_CALLS"; then
    fail "default call unexpectedly pins a model/effort"
fi
grep -q -- '--tools  --disallowedTools mcp__\* --strict-mcp-config' "$COUNCIL_STUB_CALLS" || fail "Claude tools not disabled"
grep -q -- '--sandbox read-only' "$COUNCIL_STUB_CALLS" || fail "Codex sandbox not read-only"
grep -q -- '--ignore-user-config' "$COUNCIL_STUB_CALLS" || fail "Codex config isolation missing"
if grep -q -- 'bypassPermissions\|dangerously-bypass\|--yolo' "$COUNCIL_STUB_CALLS"; then
    fail "permission bypass unexpectedly enabled"
fi
AIB_COUNCIL_CLAUDE_MODEL=custom-claude AIB_COUNCIL_CLAUDE_EFFORT=high \
AIB_COUNCIL_CODEX_MODEL=custom-codex AIB_COUNCIL_CODEX_EFFORT=medium \
PATH="$TMP:$PATH" "$ROOT/scripts/council.sh" -r 1 --consensus 0 --json "override test" > "$TMP/override.json" 2> "$TMP/override.err"
jq -e '.config.agents.claude.model == "custom-claude" and .config.agents.codex.model == "custom-codex"' "$TMP/override.json" >/dev/null || fail "explicit model overrides lost"
grep -q -- '--effort high' "$COUNCIL_STUB_CALLS" || fail "explicit Claude effort lost"
grep -q -- 'model_reasoning_effort="medium"' "$COUNCIL_STUB_CALLS" || fail "explicit Codex effort lost"
grep -q '╔════════' "$TMP/out.json" && fail "JSON output contains decorative banner"

ps -axo pid,comm,args | awk '$2 == "sleep" && $3 == "300" {print $1}' | sort > "$after_sleeps"
if comm -13 "$before_sleeps" "$after_sleeps" | grep -q .; then
    fail "watchdog leaked a sleep 300 process"
fi

echo "PASS: council defaults, --json purity, and watchdog cleanup"
