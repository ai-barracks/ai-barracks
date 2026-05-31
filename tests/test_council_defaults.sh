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
echo "Claude stub response has enough words to satisfy validation. It confirms the council path can call Claude with model and effort arguments safely."
SH

cat > "$TMP/codex" <<'SH'
#!/usr/bin/env bash
echo "CODEX_ARGS:$*" >> "${COUNCIL_STUB_CALLS:?}"
echo "Codex stub response has enough words to satisfy validation. It confirms the council path can call Codex with model and reasoning effort safely."
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
    and .config.agents.claude.model == "claude-opus-4-8"
    and .config.agents.claude.effort == "high"
    and .config.agents.gemini.enabled == false
    and .config.agents.codex.enabled == true
    and .config.agents.codex.model == "gpt-5.5"
    and .config.agents.codex.effort == "medium"
' "$TMP/out.json" >/dev/null || fail "manifest does not contain expected council defaults"

grep -q -- '--effort high' "$COUNCIL_STUB_CALLS" || fail "Claude effort flag not passed"
grep -q -- 'model_reasoning_effort="medium"' "$COUNCIL_STUB_CALLS" || fail "Codex reasoning effort override not passed"
grep -q '╔════════' "$TMP/out.json" && fail "JSON output contains decorative banner"

ps -axo pid,comm,args | awk '$2 == "sleep" && $3 == "300" {print $1}' | sort > "$after_sleeps"
if comm -13 "$before_sleeps" "$after_sleeps" | grep -q .; then
    fail "watchdog leaked a sleep 300 process"
fi

echo "PASS: council defaults, --json purity, and watchdog cleanup"
